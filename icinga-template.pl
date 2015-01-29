#!/usr/bin/perl -w
#
=head1 NAME

icinga-template.pl - Dump a icinga config from hosts list

=head1 SYNOPSIS

icinga-template.pl [options] --file=outputfile.cfg

    Options: (short)
    --verbose   (-v)       Show more details
    --help      (-h)       Show this help
    --file      (-f)       Where to write the new icinga config
    --templates (-t)       Template directory
    --restart   (-r)       Restart icinga
    --email     (-e)       Send on-call email and SMSes if changes detected

=head1 OPTIONS

=over 8

=item B<--help>

Show this message

=item B<--verbose>

Prints more details while running.

=item B<--file>

Location to write the new file to. The file is written atomicly to a temp file and then renamed to this name.

=item B<--templates>

Location of the templates. Default configured below

=item B<--restart>

Restart icinga after generating new file

=item B<--email>

Send on-call email and SMS messages if changes detected

=back

=head1 DESCRIPTION

A tool to create icinga config file from templates and database list of hosts.

=cut

use strict;
use DBI;
use Carp qw(confess cluck);
use File::Slurp;
use File::stat;
use File::Copy;
use Data::Dumper;
use Getopt::Long;
use Pod::Usage;
#use FindBin qw($RealBin);
#use lib "$RealBin/../../lib";
#use physdb;
use DBI;

my $default_template_path="/etc/icinga/templates";
my $cache_file = "/var/lib/icinga/icinga-call-cache.dat";
my $mailer = '/usr/sbin/sendmail -t';

my $staff_email = 'staff@example.com';
my $from_email = 'icinga@example.com';

my %templates; # cache to avoid re-reading from disk
my @hostgroup_list;
my @servicegroup_list;


my %options;
GetOptions( \%options, 'verbose', 'help', 'restart', 'file:s', 'templates:s', 'email' ) or confess("Error");

pod2usage(1) if ($options{'help'} or !$options{'file'});

if($options{'verbose'}) {
  print "Being verbose!\n";
}

#cfengine runs this script and it has no home environment, so we default to /root
my $pgpass;
if( exists $ENV{HOME} && defined $ENV{HOME} && $ENV{HOME} ne '' && -d $ENV{HOME}) {
  $pgpass = $ENV{HOME}."/.pgpass";
}
else {
    $pgpass = "/root/.pgpass";
}

confess("No postgres password file: $pgpass") unless( -f $pgpass );

#Get 1st line in .pgpass and use its values
my ($credStr) = read_file($pgpass);
my ($dbHost, $dbPort, $dbName, $dbUsername, $dbPassword) = split(':', $credStr);
my $dbh = DBI->connect("dbi:Pg:dbname=$dbName;port=$dbPort;host=$dbHost", "$dbUsername"); #, "$dbPassword");

my $template_path = $options{'templates'} ? $options{'templates'} : $default_template_path;

sub template_exists
{
    my $fname = shift;
    $fname = $template_path . '/'. $fname . '.cfg';
    if($options{'verbose'}) {
       print "Checking if $fname exists\n";
    }
    return stat($fname) ? 1 : 0;
}

my %macros;
sub read_template {
    my $tplname = shift;
    my $args = shift;
    my @args;
    @args = (undef, split(',', $args)) if($args);
    my $template_content = "";

    print "  read_template($tplname)\n" if($options{'verbose'});

    if (-e "$template_path/$tplname.cfg") {
            print "  reading $template_path/$tplname.cfg\n" if($options{'verbose'});
            my @template_lines = read_file("$template_path/$tplname.cfg");
            my $lineno = 0;
            foreach my $line (@template_lines) {
                $lineno++;
                if (!($line =~ /^\#/ or $line=~/^$/)) {
                   # swap out any include arguments..
                   if($line =~ /\%([0-9])\%/) {
                       my $incarg = $1;
                       if($incarg > @args) {
                           print "WARNING: $template_path/$tplname.cfg line $lineno contains an argument (%$incarg%) but none were passed\n";
                       }
                       else {
                           $line =~ s/\%([0-9])\%/${args[$1]}/g;
                       }
                   }
                   # Handle the %INCLUDE template-name% syntax
                   if($line =~ /^\W*%INCLUDE ([^%,]+),?([^%]+)?%/) {
                       $template_content .= add_template($1,$2);
                   }
                   #Set a variable
                   elsif($line =~/\W*%(\w+)\=(.*)%/) {
                       my ($key, $val) = ($1, $2);
                       # Dont overwrite existing values, because wrapping templates values should override.
                       if(!exists $macros{$key}) {
                         $macros{$key} = $val;
                       }
                   }
                   else {
                       #my $ret = eval {$line =~ s/\%([0-9])\%/${args[$1]}/g; }; 
                       #if($ret) {
                       #   print "## ERROR: $line\n";
                       #}
                       $template_content .= $line;
                   }
                }
            }
        return "$template_content";
    }
    else {
        # If the host template isnt found, complain and go on.
        if($tplname eq "host") {
            print "$template_path/$tplname.cfg not found\n";
            return "### $template_path/$tplname.cfg not found ###\n";
        }
        else {
            print "  $template_path/$tplname.cfg not found\n" if($options{'verbose'});
        }
        $template_content = "### ERROR: $template_path/$tplname.cfg was not found. Skipping ###\n";
        #$template_content = read_template("host");
        return "$template_content";
    }
}

sub add_template {
    my $template = shift;
    my $args = shift;
    return '## WARNING: undef template ##\n' unless defined $template;
    print "  add_template($template)\n" if($options{'verbose'});
    if($args or !defined($templates{$template})) {
       $templates{$template} = read_template($template, $args);
    }
    return "".$templates{$template};
}

sub query2config {
    my $sections = shift;
    my $sql = shift;
    my $hostresult = $dbh->prepare($sql);
    $hostresult->execute();
    my $config_contents = '';

    while (my $row = $hostresult->fetchrow_hashref()) {
        foreach my $section (@$sections) {
            foreach my $column (keys %$row) {
                #print "Looking at prefix $section->{name} and column $column\n";
                #my $section = $sections->{$prefix};
                if(uc($column) eq uc($section->{'key'})) {
                    my $key = uc($column);
                    my $val = $row->{$column};
                    #column $column is the key for section $prefix. 
                    #print "Found a key for section $prefix: $short_column\n";
                    
                    #If the value of this key is different than the recorded current one..
                    #print "Checking for $val\n";
                    if($val && !exists $section->{'completed'}->{$val}) {
                        #print "No entry for $key = $val, creating one\n";
                        #Seems this they key value for this section has not been defined yet. Dump its config
                        $section->{'completed'}->{$val} = 1;

                        #Uppercase the keys
                        my %replacements = map { uc $_ => $row->{$_} } keys %$row;
                        if($section->{'template'}) {
                            if($row->{lc($section->{'template'})}) {
                            
                                #print "DEBUG: generating config for $section->{name}, template=$section->{template}: ". $row->{lc($key)} . " = ". $row->{lc($section->{'template'})}. "\n";
                                #$config_contents .= "### SECTION: $prefix, template=$section->{template}\n";
                                $config_contents .= generate_config($row->{lc($section->{'template'})}, \%replacements);
                            }
                            else {
                                print "Skipping template for section $section->{name} because its blank\n";
                            }
                        }
                    }
                }
            }
        }
    }
    #print "DEBUG: \n". $config_contents. "\n";
    return $config_contents;
}

sub generate_config {
    my $template = shift;
    my $replacements = shift;

    return '\n## WARNING: undef template ##\n' unless defined $template;

    #Read in template
    my $config = add_template($template);
    # replace variables
    foreach my $old (keys %{$replacements}) {
        #print "DEBUG: $old\n";
        my $new = '';
        if($old && exists $replacements->{$old} && defined $replacements->{$old}) {
            $new = $replacements->{$old};
            $new =~ s/\R/ /g;
        }
        $config =~ s/\%$old\%/$new/ge;
    }

    foreach my $m (keys %macros) {
       $config =~ s/\%$m\%/$macros{$m}/ge;
    }
    return "\n###### $template ##########\n$config\n";
}

##########################################################################################################
# Example Config follows:
##########################################################################################################


#RULES for the query. Important! Without following these the generated config will be broken with duplicate
# entries!
#  * Everything in the SELECT list must have a prefix listed in the prefixes argument
#    use AS. for example ithwhost_hostname should be AS HOST_hostname
#  * ORDER BY must be used on the keys of each prefix in the order you want them entered: 
#       * ORDER BY CONTACT_GROUP, CONTACT, HOST_hostname, ALARM_name
#  * prefixes cannot contain _  (underscore), since that is the seperator
#  * if prefix template column is null or empty, no config will be generated for it
#  * In the select list, similar prefixed items should be grouped together, and come
#    in the same order as the ORDER BY keys for that group.

my $config = query2config(
             [
                {name=>'HOST',      key=>'HOST_HOSTNAME',   template=>'HOST_TEMPLATE'},
                {name=>'PROBE',     key=>'PROBE_NAME',      template=>'PROBE_TEMPLATE'},
                {name=>'ALARM',     key=>'ALARM_NAME',      template=>'ALARM_TEMPLATE'},
                {name=>'NOTIFY',    key=>'ALARM_NAME',      template=>'ALARM_NOTIFY_TEMPLATE'},
                {name=>'SYSTEM',    key=>'PROBE_SYSTEM',    template=>'SYSTEM_TEMPLATE'},
             ], 
          "SELECT 
                  itsmalrm_name            AS ALARM_NAME,
                  itsmalrm_alarm_template  AS ALARM_TEMPLATE,
                  itsmalrm_enable_flag     AS ALARM_ENABLE,
                  itsmalrm_descr           AS ALARM_DESCRIPTION,
                  itsmalrm_notify_template AS ALARM_NOTIFY_TEMPLATE,


                  itsmprbe_normal_value    AS PROBE_NORMAL,
                  itsmprbe_warning_min     AS PROBE_WARNING_MIN,
                  itsmprbe_warning_max     AS PROBE_WARNING_MAX,
                  itsmprbe_critical_min    AS PROBE_CRITICAL_MIN,
                  itsmprbe_critical_max    AS PROBE_CRITICAL_MAX,
                  itsmprbe_enable_flag     AS PROBE_ENABLE,
                  ivsmsyst_name            AS PROBE_SYSTEM,

                  ivsmsyst_name            AS SYSTEM_NAME,
                  'servicegroup'           AS SYSTEM_TEMPLATE,

                  itsmprbe_name            AS PROBE_NAME,
                  itsmprbe_probe_address   AS PROBE_ADDRESS,
                  itsmprbe_probe_template  AS PROBE_TEMPLATE,
                  itsmprbe_descr     AS PROBE_DESCRIPTION,

                  ithwhost_hostname        AS HOST_HOSTNAME,     
                  ithwhost_domain          AS HOST_DOMAIN, 
                  ithwhost_ip              AS HOST_IP,
                  ithwhost_nagios_template AS HOST_TEMPLATE,
                  ithwhost_flag_notify     AS HOST_ENABLE,

                  /* Returns a bunch of `-x newprobe=host:probe` arguments seperated by spaces, for use in 
                   * agregating multiple probes */
                  ARRAY_TO_STRING(ARRAY(
                        SELECT '-x \"statusdat [ '|| itsmprbe_name || ' ] = '|| ithwhost_hostname || ':' || itsmprbe_name || '\"'

                       FROM itsmprbe
                       LEFT OUTER JOIN ithwhost
                       ON (itsmprbe_hwhost_id = ithwhost_id),
                            ilalrprb
                      WHERE ilalrprb_smalrm_id = itsmalrm_id
                        AND ilalrprb_smprbe_id = itsmprbe_id
                        ), ' ') AS ALARM_PROBELIST,

                  /* Returns a comma seperated list of all staff task groups marked for this alarm, and another group 'all'
                   * to ensure it is never empty (for icinga config templates which cant handle empty).
                   * Also restrict (with EXISTS block) to groups that have members */
                  ARRAY_TO_STRING(array_append(ARRAY(
                      SELECT zvstftsk_web_page_var
                        FROM ilalrtsk
                        JOIN zvstftsk
                          ON ilalrtsk_stftsk_id = zvstftsk_id
                       WHERE ilalrtsk_smalrm_id = itsmalrm_id
                         AND EXISTS (  /* Group has at least one member */
                                SELECT ztperson_id
                                  FROM ztperson
                                  JOIN zlpertsk
                                    ON zlpertsk_person_id = ztperson_id
                                  JOIN ztcontac
                                    ON ztperson_id = ztcontac_person_id
                                  JOIN zvstftsk
                                    ON  zlpertsk_stftsk_id = zvstftsk_id


                                 WHERE ilalrtsk_smalrm_id = itsmalrm_id
                                   /* This needs to match the person query in the query2config below */
                                   AND ztperson_active_ind = 'A' 
                                   AND ztcontac_type       = 'Pers'
                             )
                    ), 'icinga'), ',') AS ALARM_GROUPS

             FROM itsmalrm
             JOIN ilalrprb
               ON ilalrprb.ilalrprb_smalrm_id = itsmalrm_id
             JOIN itsmprbe 
               ON itsmprbe.itsmprbe_id = ilalrprb_smprbe_id
             JOIN ivsmsyst
               ON ivsmsyst.ivsmsyst_id=itsmalrm.itsmalrm_smsyst_id
             JOIN ithwhost
               ON ithwhost.ithwhost_id = itsmprbe_hwhost_id

            WHERE ithwhost_active_ind='A' AND ithwhost_flag_notify='t' AND ithwhost_nagios_template IS NOT NULL"
);

$config .= query2config(
             [
                {name=>'CONTACTGROUP', key=>'CONTACTGROUP_NAME',  template=>'CONTACTGROUP_TEMPLATE'},
                {name=>'CONTACT',      key=>'CONTACT_USERNAME',       template=>'CONTACT_TEMPLATE'},
             ], 
          "
SELECT 
     'contactgroup'           AS CONTACTGROUP_TEMPLATE,
     zvstftsk_web_page_var    AS CONTACTGROUP_NAME,

     'contact'                AS CONTACT_TEMPLATE,
     ztperson_username        AS CONTACT_USERNAME,

     CASE 
        WHEN ztcontac_cell_number IS NOT NULL 
         AND ztcontac_cell_number <> '' 
     THEN ztcontac_cell_number 
     ELSE '0' 
     END as CONTACT_MOBILE,

     ztcontac_email_addr      AS CONTACT_EMAIL,
     ztcontac_name_ind || ' ' || ztcontac_name_fam AS CONTACT_NAME,

     array_to_string( array_prepend('EXAMPLE', 
        array_cat(
          array(

           SELECT DISTINCT cast('icinga_notify_oncall' as varchar(50)) as a
             FROM iticingas
            WHERE iticingas_start_date <= CURRENT_DATE AND iticingas_end_date > CURRENT_DATE
              AND (iticingas_1st_contact_person_id = ztcontac_person_id
                   OR iticingas_2nd_contact_person_id = ztcontac_person_id
                   )
          ), 
     
          array(

           SELECT zvstftsk_web_page_var
             FROM zvstftsk
             JOIN zlpertsk
               ON zlpertsk_stftsk_id = zvstftsk_id
            WHERE zlpertsk_person_id = ztperson_id
            AND zlpertsk_disable_ind = 'E'
            AND zvstftsk_active_ind = 'A'
            AND zvstftsk_disable_ind = 'E'
          )
        )),
       ',') as CONTACT_CONTACTGROUPS
       
                 
  FROM ztperson
  JOIN ztcontac
    ON ztperson_id = ztcontac_person_id
  JOIN zvusrtyp
    ON ztperson_usrtyp_id  = zvusrtyp_id
 
  JOIN zlpertsk
    ON zlpertsk_person_id = ztperson_id
  FULL JOIN zvstftsk
    ON  zlpertsk_stftsk_id = zvstftsk_id

 WHERE ztperson_active_ind = 'A' 
   AND ztcontac_type       = 'Pers'
 
          ");


#Make a backup of the config file
my $backupfile = $options{'file'}. '.backup';
if( -f $options{'file'} ) {
    if( -f $backupfile) {
        print "Removing stale file: $backupfile\n";
        unlink($backupfile);
    }
    copy($options{'file'}, $backupfile) or confess "Copy failed: $!";
}

#Write the new config file
my $oldumask = umask 0022;
write_file($options{'file'}, {atomic=>1}, \$config) or confess("Write file failed");

if($options{'restart'}) {
    #Check if config validates
    my $checkstatus = system("/usr/sbin/icinga -v /etc/icinga/icinga.cfg");
    if($checkstatus) {
        #If it doesnt validate, revert our changes
        print "Problem checking nagios config file. Reverting $options{file}.\n";
        rename($options{'file'}, $options{'file'}.'.broken');
        rename($backupfile, $options{'file'});
        print "Broken file saved as $options{file}.broken. Take a look.\n";
        exit 1;
    }

    print("Restarting icinga...\n") if($options{'verbose'});
    my $status = system("/etc/init.d/icinga restart");
    if($status != 0 ) {
      confess("Error restarting icinga!\n");
    }
}



if($options{'email'}) {
    #Check on-call list from before..
    my $prev_call;
    if( -e $cache_file) {
        $prev_call = read_file($cache_file);
        chomp $prev_call;
    }

    my $oncall_query =  "
            SELECT 
              CASE WHEN iticingas_start_date <= CURRENT_DATE AND iticingas_end_date > CURRENT_DATE 
                   THEN '1'
                   ELSE '0'
               END
                AS current_week,
             iticingas_id,
             iticingas_1st_contact_person_id,
             iticingas_2nd_contact_person_id,
             iticingas_start_date,
             iticingas_end_date,
             to_char(iticingas_start_date, 'DD-Mon-YYYY') as start,
             to_char(iticingas_end_date, 'DD-Mon-YYYY') as end,
             to_char(iticingas_start_date, 'Mon DD') as start_brief,
             to_char(iticingas_end_date, 'Mon DD') as end_brief,
             contact_1st, cell_number_1st, phone_number_1st, work_phone_number_1st, email_1st,
             contact_2nd, cell_number_2nd, phone_number_2nd, work_phone_number_2nd, email_2nd

            FROM iticingas

            LEFT OUTER JOIN 
                   (SELECT ztcontac_person_id,
                           ztcontac_name_ind || ' ' || 
                              ztcontac_name_fam                  AS contact_1st,
                           ztcontac_home_number                  AS phone_number_1st,
                           ztcontac_phone_number || '#' || 
                              ztcontac_phone_number_ext          AS work_phone_number_1st,
                           ztcontac_cell_number                  AS cell_number_1st,
                           ztcontac_pager_number                 AS pager_number_1st,
			   ztcontac_email_addr                   AS email_1st
                      FROM ztcontac
                     WHERE ztcontac_type = 'Pers') AS contact_a
                ON (iticingas_1st_contact_person_id = contact_a.ztcontac_person_id)
            LEFT OUTER JOIN 
                   (SELECT ztcontac_person_id,
                           ztcontac_name_ind || ' ' || 
                              ztcontac_name_fam                  AS contact_2nd,
                           ztcontac_home_number                  AS phone_number_2nd,
                           ztcontac_phone_number || '#' || 
                              ztcontac_phone_number_ext          AS work_phone_number_2nd,
                           ztcontac_cell_number                  AS cell_number_2nd, 
                           ztcontac_pager_number                 AS pager_number_2nd,
			   ztcontac_email_addr                   AS email_2nd
                      FROM ztcontac
                     WHERE ztcontac_type = 'Pers') AS contact_b
                ON (iticingas_2nd_contact_person_id = contact_b.ztcontac_person_id)

            WHERE iticingas_active_ind = 'A'
              AND iticingas_end_date > CURRENT_DATE

            ORDER BY iticingas_end_date asc
            LIMIT 3
    ";

    my $oncall_result = $dbh->prepare($oncall_query);
    $oncall_result->execute();
    if (my $first_row = $oncall_result->fetchrow_hashref()) {
        print Dumper($first_row);
        if(!$first_row->{'current_week'}) {
            print "ERROR: first row was not current\n";
            #No current week found. Hassle IT to add call schedules!
            #TODO: email it@zebrafish a hassling email
        }
        else {
            if( !$prev_call || $prev_call ne $first_row->{'iticingas_id'}) {
                print "1st Call now $first_row->{contact_1st} ($first_row->{iticingas_1st_contact_person_id})\n";
                print "2nd Call now $first_row->{contact_2nd} ($first_row->{iticingas_2nd_contact_person_id})\n";
                my $next_call = '';
		my $rowcount = 1;
                while(my $row = $oncall_result->fetchrow_hashref()) {
                    print Dumper($row);
                    $next_call .= "$row->{start} to $row->{end}: $row->{contact_1st} & $row->{contact_2nd}\n";
		    #Send emails to next weeks call person
		    if(++$rowcount == 2) {
		        send_reminder_email($row);
		    }
                }
                send_call_email("$first_row->{start} to $first_row->{end}: $first_row->{contact_1st} & $first_row->{contact_2nd}", "$next_call");
                if($first_row->{"cell_number_1st"}) {
                    send_sms($first_row->{"cell_number_1st"}, "You are now on EXAMPLE primary call from $first_row->{start_brief} to $first_row->{end_brief}. Text me 'HELP' or 'STATUS' for icinga information");
                    send_sms($first_row->{"cell_number_1nd"}, "You are backed up by $first_row->{contact_2nd} (cell: $first_row->{cell_number_2nd}, home: $first_row->{phone_number_2nd}, work: $first_row->{work_phone_number_2nd})"); 
                }
                if($first_row->{"cell_number_2nd"}) {
                    send_sms($first_row->{"cell_number_2nd"}, "You are now on EXAMPLE secondary call from $first_row->{start_brief} to $first_row->{end_brief}. Text me 'HELP' or 'STATUS' for icinga information");
                    send_sms($first_row->{"cell_number_2nd"}, "You are backing up $first_row->{contact_1st} (cell: $first_row->{cell_number_1st}, home: $first_row->{phone_number_1st}, work: $first_row->{work_phone_number_1st})"); 
                }

                #Update status cache
                write_file($cache_file, $first_row->{iticingas_id});
            }
            else {
                print "DEBUG: 1st Call still $first_row->{contact_1st} ($first_row->{iticingas_1st_contact_person_id})\n";
                print "DEBUG: 2nd Call still $first_row->{contact_2nd} ($first_row->{iticingas_2nd_contact_person_id})\n";
            }
        }
    }
}

sub send_call_email {
    my $call_now = shift;
    my $call_next = shift;

    my $to = $staff_email;
    my $from = $from_email;
    my $subject = "icinga On-Call This Week: $call_now";
    my $body = 
"icinga On-Call This Week: $call_now

Upcoming Weeks:
$call_next

";
    open(MAIL, "| $mailer");
    print MAIL "To: $to\n";
    print MAIL "From: $from\n";
    print MAIL "Subject: $subject\n";
    print MAIL "Content-type: text/plain\n\n";
    print MAIL $body;
    close MAIL;
    print "On-call email sent to $to\n";
}

sub send_reminder_email {
    my $info = shift;

    my $to = "$info->{email_1st},$info->{email_2nd}";
    my $from = $from_email;
    my $subject = "REMINDER: You are scheduled to be on-call next Week: $info->{start} to $info->{end}";
    my $body = 
"
REMINDER: You are scheduled to be on-call next Week: $info->{start} to $info->{end}. 

If for any reason you cannot be, arrange to swap with someone, and make the changes yourself at https://example.com/EXAMPLE/staff/icinga/icingaScheduleLst.php

Thanks,

Alex (6-8255)
Ron (6-8253)
";
    open(MAIL, "| $mailer");
    print MAIL "To: $to\n";
    print MAIL "From: $from\n";
    print MAIL "Subject: $subject\n";
    print MAIL "Content-type: text/plain\n\n";
    print MAIL $body;
    close MAIL;
    print "Reminder email sent to $to\n";
}


sub send_sms {
    my $to = shift;
    my $message = shift;

    $to =~ s/[^0-9]+//g;
    #for debugging
    #$to = '5419796898';
    system("/etc/icinga/plugins/sendsms.pl -H 128.223.30.38 -u icinga -p PASSWORDHERE -n '$to' -m '$message'");
}

umask $oldumask;

