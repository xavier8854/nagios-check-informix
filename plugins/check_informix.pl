#!/usr/bin/perl -w

#######################################################################
# $Id: check_informix.pl, v1.0 r1 16.03.2021 12:11:38 CET XH Exp 001.001$
#
# Copyright 2021 Xavier Humbert <xavier.humbert@ac-nancy-metz.fr>
# for CRT SUP
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301, USA.
#
#######################################################################

use strict;
use warnings;
use Monitoring::Plugin ;

use Data::Dumper;
use DBI qw(:sql_types);
#~ use DBD::Informix qw(:ix_types);
use File::Basename;
use Locale::gettext;
use Getopt::Long;
use POSIX qw(:signal_h floor setlocale);
use Time::HiRes;			# get microtime
use DateTime;
use Config::IniFiles;

use lib '/home/xavier/Development/rpmbuild/src/perl-PrometheusMetrics/lib/';
use PrometheusMetrics;

#####
## PROTOS
#####
sub ifx_uptime();
sub ifx_version();
sub ifx_status();
sub ifx_size_dbspaces();
sub ifx_ratio_dbspaces();
sub ifx_db_list();
sub ifx_db_sizes();
sub ifx_log_size();
sub ifx_locked_sessions();
sub ifx_checkpoints();
sub ifx_chunkoffline ();
sub ifx_ioperchunk ();
sub ifx_stats ();
sub ifx_infos ();
sub ifx_sharedmemstats ();
sub ifx_mempoolstats ();
sub ifx_bigsessions;
sub ifx_totalmem ();
sub ifx_non_saved_logs ();
sub ifx_list_logs ();

sub ifx_request($);
sub uom2megabytes($$);
sub timeoutExit();
sub logD($);
sub logInfo ($);
sub chomp_ext($);

#####
## CONSTANTS
#####
our $PROGNAME = basename($0);
our $VERSION = "1.1";
our $INFORMIXDIR='/opt/IBM/Informix_Client-SDK/';
our $LOGTOFILE = 0;

our @COMMANDS = (
		'uptime',
		'version',
		'status',
		'dbspaces',
		'ratio',
		'list',
		'dbsizes',
		'logsize',
		'locksessions',
		'checkpoints',
		'chunkoffline',
		'ioperchunk',
		'statistics',
		'infos',
		'sharedmemstats',
		'mempoolstats',
		'bigsessions',
		'totalmem',
		'nonsavedlogs',
		'listlogs',
);
our $ThresFileName = "/etc/nagios/extraopts/informix.ini";

use constant {
		uptime => 0,
		version => 1,
		status => 2,
		dbspaces => 3,
		ratio => 4,
		list => 5,
		dbsizes => 6,
		logsize => 7,
		locksessions => 8,
		checkpoints => 9,
		chunkoffline => 10,
		ioperchunk => 11,
		statistics => 12,
		infos => 13,
		sharedmemstats => 14,
		mempoolstats => 15,
		bigsessions => 16,
		totalmem => 17,
		nonsavedlogs => 18,
		listlogs => 19,
};

#####
## VARIABLES
#####
my $np;
my $rc=0;
my $dbh;
my $DEBUG = 0;
my $TIMEOUT = 3600;
#####
## MAIN
#####
logD ("Entering main");

$np = Monitoring::Plugin->new(
	version => $VERSION,
	blurb => 'Plugin to check Informix database',
	usage => "Usage: %s [ -v|--verbose ]  -H <host> -p <port> -i <instance name> -b <database name> -c <connection type> -C <command> [-S SQL <statement>] [-t <timeout>] [ -c{t|a|b|l}=<threshold> ] [ -w{t|a|b|l}=<threshold> ]",
	timeout => $TIMEOUT+1
);


$np->add_arg (
	spec => 'debug|d',
	help => 'Debug level',
	default => 0,
	required => 0,
);

$np->add_arg (
	spec => 'hostaddr|H=s',
	help => 'Host addr',
	required => 1,
);
$np->add_arg (
	spec => 'hostname|F=s',
	help => 'Host fqdn',
	required => 1,
);
$np->add_arg (
	spec => 'hostID|I=s',
	help => 'Nagios hots naem',
	required => 1,
);

$np->add_arg (
	spec => 'port|p=i',
	help => 'Database listen port',
	required => 1,
);

$np->add_arg (
	spec => 'nettype|n=s',
	help => 'Connection type',
	required => 0,
	default => 'onsoctcp'
);

$np->add_arg (
	spec => 'command|C=s',
	help => join (',', @COMMANDS),
	required => 1,
);

$np->add_arg (
	spec => 'statement|S=s',
	help => 'SQL statement to execute in conjunction with execsql command',
	required => 0,
);

$np->add_arg (
	spec => 'instance|i=s',
	help => 'Instance name',
	required => 1,
);

$np->add_arg (
	spec => 'base|b=s',
	help => 'Database name',
	required => 0,
	default => 'sysmaster'
);

$np->add_arg (
	spec => 'user|u=s',
	help => 'Connection user name',
	required => 1,
);
$np->add_arg (
	spec => 'password|w=s',
	help => 'Connection user password',
	required => 1,
);
$np->add_arg (
	spec => 'env|e=s',
	help => 'Nagios environment',
	required =>  1,
);

$np->add_arg (
	spec => 'wt=f',
	help => 'Warning request time threshold (in seconds)',
	default => 2,
	required => 0,
	label => 'FLOAT'
);

$np->add_arg (
	spec => 'ct=f',
	help => 'Critical request time threshold (in seconds)',
	default => 10,
	required => 0,
	label => 'FLOAT'
);

$np->add_arg (
	spec => 'wb=i',
	help => 'Warning backup age threshold (in hours)',
	default => 0,
	required => 0,
);

$np->add_arg (
	spec => 'cb=i',
	help => 'Critical backup age threshold (in hours)',
	default => 0,
	required => 0,
);

$np->add_arg (
	spec => 'wa=i',
	help => 'Warning agent used threshold (in % of MAX_AGENTS)',
	default => 0,
	required => 0,
);

$np->add_arg (
	spec => 'ca=i',
	help => 'Critical agent used threshold (in % of MAX_AGENTS)',
	default => 0,
	required => 0,
);

$np->add_arg (
	spec => 'wl=i',
	help => 'Warning number of LOCKS_WAITING threshold',
	default => 0,
	required => 0,
);

$np->add_arg (
	spec => 'cl=i',
	help => 'Critical number of LOCKS_WAITING threshold',
	default => 0,
	required => 0,
);

$np->add_arg (
	spec => 'ws=i',
	help => 'Warning size threshold',
	default => 0,
	required => 0,
);

$np->add_arg (
	spec => 'cs=i',
	help => 'Critical size threshold',
	default => 0,
	required => 0,
);

logD ("Getting command line options");
$np->getopts;

$DEBUG = $np->opts->get('debug');

my $hostaddr = $np->opts->get('hostaddr');
my $hostfqdn = $np->opts->get('hostname');
my $hostID = $np->opts->get('hostID');
my $port = $np->opts->get('port');
my $instance =  $np->opts->get('instance');
my $db = $np->opts->get('base');
my $nettype  = $np->opts->get('nettype');
my $command  = $np->opts->get('command');
my $user = $np->opts->get('user');
my $pass = $np->opts->get('password');
my $topase_env = $np->opts->get('env');


# Thresholds :
# time
my $warn_t = $np->opts->get('wt');
my $crit_t = $np->opts->get('ct');
# agents
my $warn_a = $np->opts->get('wa');
my $crit_a = $np->opts->get('ca');
# backups
my $warn_b = $np->opts->get('wb');
my $crit_b = $np->opts->get('cb');
# lock wait
my $warn_l = $np->opts->get('wl');
my $crit_l = $np->opts->get('cl');
# sizes
my $warn_s = $np->opts->get('ws');
my $crit_s = $np->opts->get('cs');

# Setup Informix environnement
$ENV{'DBD_INFORMIX_DATABASE'}='sysmaster'						unless ( defined($ENV{'DBD_INFORMIX_DATABASE'}) );
$ENV{'DBD_INFORMIX_USERNAME'}=$user;
$ENV{'INFORMIXDIR'}=$INFORMIXDIR								unless ( defined($ENV{'INFORMIXDIR'}) );
$ENV{'DBI_DBNAME'}='sysmaster'									unless ( defined($ENV{'DBI_DBNAME'}) );
$ENV{'INFORMIXSQLHOSTS'}="$INFORMIXDIR/etc/sqlhosts";
$ENV{'INFORMIXSERVER'} = $instance;

if (not -d $ENV{'INFORMIXDIR'}) {
	$np->nagios_exit (CRITICAL, "Directory $ENV{'INFORMIXDIR'} does not exist") ;
}

### Write sqlhosts file from cl infos
my $sqlhosts = $ENV{'INFORMIXDIR'} . "/etc/sqlhosts";
if (-f $sqlhosts) {
	logD ("SQLHosts file exists, overwriting conditionnaly");
}
open (my $sqlfh, '+<', $sqlhosts) or die "Cannot open sqlhosts file $!";

	my $content = <$sqlfh>;
	my ($old_instance, $old_nettype, $old_hostaddr, $old_port) = split ("\t", chomp_ext($content));
	if (($instance ne $old_instance ) or ($nettype ne $old_nettype) or ($hostaddr ne $old_hostaddr) or ($port ne $old_port)) {
		seek ($sqlfh, 0, 0);
		printf $sqlfh "%s\t%s\t%s\t%s\n", $instance, $nettype, $hostaddr, $port;
		logD ("SQL Hosts file modified !");
	}
close $sqlfh;

### Before connectiong, setup a safe guard for timeout
my $mask = POSIX::SigSet->new( SIGALRM );
my $action = POSIX::SigAction->new(\&timeoutExit,$mask);
my $oldaction = POSIX::SigAction->new();
sigaction( SIGALRM, $action, $oldaction );
logD( "Seting Alarm timeout to $TIMEOUT");
my $startTime = Time::HiRes::time();
alarm($TIMEOUT);

### Connect to DB
logD ("Connect to DB $hostfqdn");

my $drh = DBI->install_driver('Informix');
eval {
	$dbh = DBI->connect("dbi:Informix:$db\@$instance", $user, $pass, { RaiseError => 0, AutoCommit => 0 });
} or do {
	my $msg = "Query failed (connect): ";
	if (defined $DBI::errstr) {
		$msg .= $DBI::errstr;
	}
	logD($msg);
	$np->nagios_exit(CRITICAL, $msg );
};

logD ("**** Executing Command " . $command . "****");

   if ($command eq $COMMANDS[uptime])			{ ifx_uptime ();			}
elsif ($command eq $COMMANDS[version])			{ ifx_version ();			}
elsif ($command eq $COMMANDS[status])			{ ifx_status ();			}
elsif ($command eq $COMMANDS[dbspaces])			{ ifx_size_dbspaces ();		}
elsif ($command eq $COMMANDS[ratio])			{ ifx_ratio_dbspaces ();	}
elsif ($command eq $COMMANDS[list])				{ ifx_db_list ();			}
elsif ($command eq $COMMANDS[dbsizes])			{ ifx_db_sizes ();			}
elsif ($command eq $COMMANDS[logsize])			{ ifx_log_size ();			}
elsif ($command eq $COMMANDS[locksessions])		{ ifx_locked_sessions ();	}
elsif ($command eq $COMMANDS[checkpoints])		{ ifx_checkpoints ();		}
elsif ($command eq $COMMANDS[chunkoffline])		{ ifx_chunkoffline ();		}
elsif ($command eq $COMMANDS[ioperchunk])		{ ifx_ioperchunk ();		}
elsif ($command eq $COMMANDS[statistics])		{ ifx_stats ();				}
elsif ($command eq $COMMANDS[infos])			{ ifx_infos ();				}
elsif ($command eq $COMMANDS[sharedmemstats])	{ ifx_sharedmemstats ();	}
#~ elsif ($command eq $COMMANDS[mempoolstats])		{ ifx_mempoolstats ();		}
elsif ($command eq $COMMANDS[bigsessions])		{ ifx_bigsessions ();		}
elsif ($command eq $COMMANDS[totalmem])			{ ifx_totalmem ();			}
elsif ($command eq $COMMANDS[nonsavedlogs])		{ ifx_non_saved_logs ();	}
elsif ($command eq $COMMANDS[listlogs])			{ ifx_list_logs ();			}
else 											{ $np->nagios_exit(CRITICAL, "Unknown command : " . $command )	}
$dbh->disconnect ();

my $endTime = Time::HiRes::time();
my $elapsed = $endTime - $startTime;

logD (sprintf ("Elapsed time : %.2f", $elapsed));

my ($final_status, $final_message) = $np->check_messages();

$np->nagios_exit($final_status, $final_message );



exit ($rc);

#######################################################################

#####
## FUNCTIONS
#####

sub ifx_uptime(){
	my $stmt = << "SQL";
select DBINFO ('utc_to_datetime', sh_boottime ) from sysshmvals;
SQL

	my $ref = ifx_request($stmt);
	my ($date, $time) = split (' ', $ref->[0][0]);
	my ($year, $month, $day) = split ('-', $date);
	my ($hour, $min, $sec) = split (':', $time);
	my $uptimedate = DateTime->new (
		year => $year, month => $month, day => $day,
		hour => $hour, minute => $min, second => $sec);
	my $now = DateTime->now();
	my $uptime =$now->subtract_datetime($uptimedate);
	my $uptime_metrics = PrometheusMetrics->new (
		'metric_name' => "ifx_uptime", 'metric_help' => "Informix uptime",
		'metric_type' => 'counter', 'metric_unit' => 'seconds', 'hostaddr' => $hostaddr,'env' => $topase_env, 'outdir'=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	$uptime_metrics->declare ("ifx_uptime", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysshmvals", 'env' => $topase_env,});
	my $uptimeseconds = $uptime->seconds() + 60 * ($uptime->minutes() + 60 * ($uptime->hours() + 24 * ($uptime->days() + 30.5 * ($uptime->months() + 12 * $uptime->years()))));
	$uptime_metrics->set ($uptimeseconds);
	$np->add_message (OK, sprintf ("%iy %im %id %ih %imn %is", $uptime->years(), $uptime->months(), $uptime->days(), $uptime->hours(), $uptime->minutes(), $uptime->seconds()));
	$uptime_metrics->print_file ('>' );
}

sub ifx_version(){
	my $stmt = << "SQL";
select DBINFO('version','full');
SQL
	my $version_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_version", 'metric_help'	=> "Informix Version", 'metric_type'	=> 'gauge',
		'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $ref = ifx_request($stmt);
	$version_metrics->declare ("ifx_version", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "DBINFO", 'env' => $topase_env, 'version' => $ref->[0][0]});
	$version_metrics->set(1);
	$np->add_message (OK, $ref->[0][0]);
	$version_metrics->print_file ('>');
}

sub ifx_status(){
	my $stmt = << "SQL";
select sh_mode from sysmaster:sysshmvals;
SQL

	my $ref = ifx_request($stmt);
	my $status = int($ref->[0][0]);
	my $msg = '';

	if ($status == 0)		{ $msg = 'Initialisation';	}
	elsif ($status == 1)	{ $msg = 'Quiescent';		}
	elsif ($status == 2)	{ $msg = 'Recovery';		}
	elsif ($status == 3)	{ $msg = 'Backup';			}
	elsif ($status == 4)	{ $msg = 'Shutdown';		}
	elsif ($status == 5)	{ $msg = 'Online';			}
	elsif ($status == -1)	{ $msg = 'Offline';			}

	my $status_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_status", 'metric_help'	=> "Informix Status", 'metric_type'	=> 'gauge',
		'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	$status_metrics->declare ("ifx_status", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysshmvals", 'env' => $topase_env,});
	$status_metrics->set($status);
	$np->add_message (OK, $msg);
	$status_metrics->print_file ('>');
}

sub ifx_size_dbspaces(){
	my $combinedStatus = OK;
	my $failedDB = "";
	my $stmt  = << "SQL";
select dbsname, format_units(sum(size)*2048,'b') SIZE
from sysextents where dbsname not like 'sys%' group by dbsname
order by 2 desc;
SQL

	my $ref = ifx_request($stmt);
	my @dblist = @{$ref};
	my $dbspaces_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_dbspaces", 'metric_help'	=> "Informix DB spaces", 'metric_type'	=> 'gauge',
		'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $numdatabase = scalar (@dblist);
	foreach my $db (@dblist) {
		my $dbName = chomp_ext($db->[0]);
		my $dbsize = chomp_ext($db->[1]);

		my ($sizevalue, $uom) = split (' ', $dbsize);
		$sizevalue =  uom2megabytes($sizevalue, $uom);
		$sizevalue = sprintf ("%.03f", $sizevalue);

		$np->add_perfdata('label' => $dbName, 'value' => $sizevalue, 'uom' => 'MB',);

		$dbspaces_metrics->declare ("ifx_dbspaces", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbName, 'env' => $topase_env,});
		$dbspaces_metrics->set ($sizevalue);

		open (my $TreshFile, '<', $ThresFileName) or die "Can't open $ThresFileName $!";
			my $cfg = Config::IniFiles->new( -file => $TreshFile);
			my $tmp = $hostfqdn;
			$tmp =~ /([a-z0-9-]+)\..*/;
			my $section = uc($1) . "_" . uc($instance) . "_THRESH_DBSPACE";
			my $value = $cfg->val($section, lc($dbName));
			$value = "0,0" unless defined $value;
			($warn_s, $crit_s) = split (/[,\s]+/, $value);
			chomp($warn_s); chomp($crit_s);
			$warn_s =~ s/\"//g; $crit_s =~ s/\"//g;
		close ($TreshFile);
		my $status = OK;

		$status = $np->check_threshold('check' => $sizevalue, 'warning' => $warn_s, 'critical' => $crit_s,);
		if ($warn_s != 0 or $crit_s !=0) {
			if ($status != OK) {
				$combinedStatus = $status if $status > $combinedStatus ;
				$failedDB .= $dbName . " ";
			}
		} else {
			$combinedStatus = OK;
		}
	}
	if ( $combinedStatus == OK) {
		$np->add_message(OK, sprintf "%i databases OK", $numdatabase);
	} else {
		$np->add_message($combinedStatus, "One or more database ($failedDB) is out of range. Check perf datas");
	}
	$dbspaces_metrics->print_file ('>');
}

sub ifx_ratio_dbspaces(){
	my $stmt  = << "SQL";
select d.dbsnum,
name dbspace,
sum(chksize) Pages_size,
sum(chksize) - sum(nfree) Pages_used,sum(nfree) Pages_free,
round ((sum(nfree)) / (sum(chksize)) * 100, 2) Percent_free
from sysdbspaces d, syschunks c
where d.dbsnum = c.dbsnum
and d.is_blobspace = 0
group by 1, 2 order by 1;
SQL
	my $ref = ifx_request($stmt);
	my @dblist = @{$ref};

	my $ratio_dbspaces_metrics_pagessize = PrometheusMetrics->new (
		'metric_name'	=> "ifx_ratio_dbspace_pagessizes", 'metric_help'	=> "Informix Ratio DB spaces page sizes",
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	my $ratio_dbspaces_metrics_pagesfree = PrometheusMetrics->new (
		'metric_name'	=> "ifx_ratio_dbspaces_pagesfree", 'metric_help'	=> "Informix Ratio DB spaces pages free",
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	my $ratio_dbspaces_metrics_pctfree = PrometheusMetrics->new (
		'metric_name'	=> "ifx_ratio_dbspaces_pctfree", 'metric_help'	=> "Informix Ratio DB spaces % free",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '%', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $numdatabase = scalar (@dblist);
	foreach my $db (@dblist) {
		my $dbID = chomp_ext($db->[0]);
		my $dbName = chomp_ext($db->[1]);
		my $pagesSize = chomp_ext($db->[2]);
		my $pagesFree = chomp_ext($db->[3]);
		my $pctFree = chomp_ext($db->[4]);
		$np->add_perfdata('label' => 'db_name', value=>$dbName);
		$np->add_perfdata('label' => 'pages_size', value=>$pagesSize);
		$np->add_perfdata('label' => 'pages_free', value=>$pagesFree);
		$np->add_perfdata('label' => 'free%', value=>$pctFree);

		$ratio_dbspaces_metrics_pagessize->declare ("ifx_ratio_dbspace_pagessizes", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbName, 'env' => $topase_env,});
		$ratio_dbspaces_metrics_pagessize->set ($pagesSize);
		$ratio_dbspaces_metrics_pagesfree->declare ("ifx_ratio_dbspaces_pagesfree", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbName, 'env' => $topase_env,});
		$ratio_dbspaces_metrics_pagesfree->set ($pagesFree);
		$ratio_dbspaces_metrics_pctfree->declare ("ifx_ratio_dbspaces_pctfree", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbName, 'env' => $topase_env,});
		$ratio_dbspaces_metrics_pctfree->set ($pctFree);
	}
	$np->add_message(OK, sprintf "%i databases OK", $numdatabase);
	$ratio_dbspaces_metrics_pagessize->print_file ('>');
	$ratio_dbspaces_metrics_pagesfree->print_file ('>');
	$ratio_dbspaces_metrics_pctfree->print_file ('>');

}

sub ifx_db_list(){
	my $stmt  = << 'SQL';
select  dbinfo("DBSPACE",partnum) dbspace, name database,
owner, is_logging, is_buff_log
from sysdatabases order by dbspace, name;
SQL
	my $ref = ifx_request($stmt);
	my @dblist = @{$ref};

	my $dblist_metrics_logging = PrometheusMetrics->new (
		'metric_name'	=> "ifx_db_logging", 'metric_help'	=> "Informix DB is logging",
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $dblist_metrics_bufflog = PrometheusMetrics->new (
		'metric_name'	=> "ifx_db_buflog", 'metric_help'	=> "Informix DB is buffered logging",
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $numdatabase = scalar (@dblist);
	foreach my $db (@dblist) {
		my $dbspace = chomp_ext($db->[0]);
		my $database = chomp_ext($db->[1]);
		my $owner = chomp_ext($db->[2]);
		my $is_logging = chomp_ext($db->[3]);
		my $is_buff_log = chomp_ext($db->[4]);

		$np->add_perfdata('label' => $dbspace.$database.'_isLogging', 'value' => $is_logging);
		$np->add_perfdata('label' => $dbspace.$database.'_isBuffLog', 'value' => $is_buff_log);

		$dblist_metrics_logging->declare ("ifx_db_logging", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbspace.$database, 'env' => $topase_env,});
		$dblist_metrics_logging->set ($is_logging);
		$dblist_metrics_bufflog->declare ("ifx_db_buflog", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbspace.$database, 'env' => $topase_env,});
		$dblist_metrics_bufflog->set ($is_buff_log);
	}
	$np->add_message (OK, sprintf "%i databases OK", $numdatabase);
	$dblist_metrics_logging->print_file ('>');
	$dblist_metrics_bufflog->print_file ('>');
}

sub ifx_db_sizes(){
	my $combinedStatus = OK;
	my $failedDB = "";
	my $stmt  = << 'SQL';
SELECT   n.dbsname DATABASE,
    round((SUM(i.ti_npused * i.ti_pagesize)/1024/1024),2)  USED_SIZE_MB,
    round((SUM(i.ti_npdata * i.ti_pagesize)/1024/1024),2)  DATA_SIZE_MB,
    round((SUM((i.ti_npused - i.ti_npdata) * i.ti_pagesize)/1024/1024),2) INDEX_SIZE_MB
FROM systabnames n, systabinfo i, sysdatabases d
WHERE    n.partnum = i.ti_partnum
AND      n.dbsname = d.name AND n.dbsname not like 'sys%'
GROUP BY 1;
SQL
	my $min = 0;
	my $max = int(1.5*$crit_s);

	my $ref = ifx_request($stmt);
	my @dblist = @{$ref};


	my $dbUsedSize_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_db_usedsize", 'metric_help'	=> "Informix DB Sizes (used)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $dbDataSize_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_db_datasize", 'metric_help'	=> "Informix DB Sizes (data)",,
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $dbIndexSize_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_db_indexsize", 'metric_help'	=> "Informix DB Sizes (index)",,
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $numdatabase = scalar (@dblist);
	foreach my $db (@dblist) {
		my $dbName = chomp_ext ($db->[0]);
		my $dbUsedSize = chomp_ext ($db->[1]);
		my $dbDataSize = chomp_ext ($db->[2]);
		my $dbIndexSize = chomp_ext ($db->[3]);
		$np->add_perfdata('label' => $dbName.'_used_size', 'value' => $dbUsedSize, 'uom' => 'MB', $min, $max);
		$np->add_perfdata('label' => $dbName.'_data_size', 'value' => $dbDataSize, 'uom' => 'MB', $min, $max);
		$np->add_perfdata('label' => $dbName.'_index_size', 'value' => $dbIndexSize, 'uom' => 'MB', $min, $max);

		$dbUsedSize_metrics->declare("ifx_db_usedsize", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbName, 'env' => $topase_env,});
		$dbDataSize_metrics->declare("ifx_db_datasize", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbName, 'env' => $topase_env,});
		$dbIndexSize_metrics->declare("ifx_db_indexsize", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => $dbName, 'env' => $topase_env,});
		$dbUsedSize_metrics->set($dbUsedSize);
		$dbDataSize_metrics->set($dbDataSize);
		$dbIndexSize_metrics->set($dbIndexSize);


		open (my $TreshFile, '<', $ThresFileName) or die "Can't open $ThresFileName $!";
			my $cfg = Config::IniFiles->new( -file => $TreshFile);
			my $tmp = $hostfqdn;
			$tmp =~ /([a-z0-9-]+)\..*/;
			my $section = uc($1) . "_" . uc($instance) . "_THRESH_DBSIZE";
			my $value = $cfg->val($section, lc($dbName));
			$value = "0,0" unless defined $value;
			($warn_s, $crit_s) = split (/[,\s]+/, $value);
			chomp($warn_s); chomp($crit_s);
			$warn_s =~ s/\"//g; $crit_s =~ s/\"//g;
		close ($TreshFile);
		my $status = OK;
		if ($warn_s != 0 or $crit_s !=0) {
			$status = $np->check_threshold('check' => $dbUsedSize, 'warning' => $warn_s, 'critical' => $crit_s);
			if ($status != OK) {
				$combinedStatus = $status if $status > $combinedStatus ;
				$failedDB .= $dbName . " ";
			}
		} else {
			$combinedStatus = OK;
		}
	}
	if ( $combinedStatus == OK) {
		$np->add_message(OK, sprintf "%i databases OK", $numdatabase);
	} else {
		$failedDB = chomp_ext($failedDB);
		$np->add_message($combinedStatus, "One or more database ($failedDB) is out of range. Check perf datas");
	}
	$dbUsedSize_metrics->print_file ('>');
	$dbDataSize_metrics->print_file ('>');
	$dbIndexSize_metrics->print_file ('>');

}

sub ifx_log_size(){
	my $stmt = << "SQL";
	select pl_physize, pl_phyused, round ((pl_phyused * 100.0)/pl_physize,2) pct_used from sysplog;
SQL

	my $min = 0;
	my $max = int(1.5*$crit_s);

	my $ref = ifx_request($stmt);
	my @dblist = @{$ref};			# pl_physize pl_phyused pct_used

	my $pl_physize = chomp_ext ($dblist[0]->[0]);
	my $pl_phyused = chomp_ext ($dblist[0]->[1]);
	my $pct_used = chomp_ext ($dblist[0]->[2]);

	my $dbLogPhysical_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_log_physical_size", 'metric_help'	=> "Informix log sizes (physical)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $dbLogUsed_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_log_used_size", 'metric_help'	=> "Informix log sizes (physical used)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> 'MB', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $dbLogPctUsed_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_log_percent", 'metric_help'	=> "Informix log sizes (pct used)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '%', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	$np->add_perfdata(label => 'log_physical_size', 'value' => $pl_physize, 'uom' => 'MB', $min, $max);
	$np->add_perfdata(label => 'log_used_size', 'value' => $pl_phyused, 'uom' => 'MB', $min, $max);
	$np->add_perfdata(label => 'log_percent', 'value' => $pct_used, 'uom' => '%', 0, 100);
	my $status = $np->check_threshold ('check' => $pct_used, 'warning' => $warn_s, 'critical' => $crit_s);

	$dbLogPhysical_metrics->declare ("ifx_log_physical_size", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysplog", 'env' => $topase_env,});
	$dbLogUsed_metrics->declare ("ifx_log_used_size", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysplog", 'env' => $topase_env,});
	$dbLogPctUsed_metrics->declare ("ifx_log_percent", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysplog", 'env' => $topase_env,});
	$dbLogPhysical_metrics->set ($pl_physize);
	$dbLogUsed_metrics->set ($pl_phyused);
	$dbLogPctUsed_metrics->set ($pct_used);

	$np->add_message ($status, sprintf "PHY LOG SIZE %s/%s (%s%%)\n", $pl_phyused, $pl_physize, $pct_used);

	$dbLogPhysical_metrics->print_file ('>');
	$dbLogUsed_metrics->print_file ('>');
	$dbLogPctUsed_metrics->print_file ('>');
}

sub ifx_locked_sessions(){
	my $stmt  = << "SQL";
select username,pid,is_wlock,is_wckpt,is_incrit
from syssessions
where is_wlock <> '0' or is_wckpt <> '0' or is_incrit <> '0'
order by username;
SQL

	my $ref = ifx_request($stmt);
	my @dblist = @{$ref};			# pl_physize pl_phyused pct_used

	my $dbLockSessions_is_lock_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_locked_sessions_is_wlock", 'metric_help'	=> "Informix sessions (is locked)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	my $dbLockSessions_is_wkpt_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_locked_sessions_is_wkpt", 'metric_help'	=> "Informix sessions (is work point)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	my $dbLockSessions_is_incrit_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_locked_sessions_is_incrit", 'metric_help'	=> "Informix sessions (is in critical section)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $numsessions = scalar (@dblist);
	foreach my $db (@dblist) {
		my $username = chomp_ext ($db->[0]);
		my $pid = chomp_ext ($db->[1]);
		my $is_wlock = chomp_ext ($db->[2]);
		my $is_wckpt = chomp_ext ($db->[3]);
		my $is_incrit = chomp_ext ($db->[4]);
		$np->add_perfdata(label => $username.'_is_wlock', 'value' => $is_wlock, 'uom' => 'y/n');
		$np->add_perfdata(label => $username.'_is_wckpt', 'value' => $is_wckpt, 'uom' => 'y/n');
		$np->add_perfdata(label => $username.'_is_incrit', 'value' => $is_incrit, 'uom' => 'y/n');

		$dbLockSessions_is_lock_metrics->declare ("ifx_locked_sessions_is_wlock", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "syssessions", 'env' => $topase_env,});
		$dbLockSessions_is_lock_metrics->set ($is_wlock);
		$dbLockSessions_is_wkpt_metrics->declare ("ifx_locked_sessions_is_wkpt", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "syssessions", 'env' => $topase_env,});
		$dbLockSessions_is_wkpt_metrics->set ($is_wckpt);
		$dbLockSessions_is_incrit_metrics->declare ("ifx_locked_sessions_is_incrit", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "syssessions", 'env' => $topase_env,});
		$dbLockSessions_is_incrit_metrics->set ($is_incrit);
	}

	$np->add_message (OK, sprintf "%i sessions locked", $numsessions);

	$dbLockSessions_is_lock_metrics->print_file ('>');
	$dbLockSessions_is_wkpt_metrics->print_file ('>');
	$dbLockSessions_is_incrit_metrics->print_file ('>');
}

sub ifx_checkpoints () {
	my $combinedStatus = OK;
	my $totalcheckpoints = 0;
	my $stmt  = << "SQL";
select
	type,
	count(*) num_checkpoints,
	max ( dbinfo( "utc_to_datetime", clock_time)) last_checkpoint,   -- Clock time of the checkpoint
	max ( cp_time ) max_checkpoint_time, -- Duration of the checkpoint in fractional seconds
	sum ( cp_time ) sum_checkpoint_time, -- Duration of the checkpoint in fractional seconds
	max ( n_crit_waits ) max_crit_waits, -- Number of processes that had to wait for the checkpoint
	sum ( n_crit_waits ) sum_crit_waits, -- Number of processes that had to wait for the checkpoint
	max ( tot_crit_wait ) max_crit_sec, -- Total time all processes waited for the checkpoint - fractional seconds
	sum ( tot_crit_wait ) sum_crit_sec, -- Total time all processes waited for the checkpoint - fractional seconds
	max ( block_time ) max_block_time, -- Longest any process had to wait for the checkpoint - fractional seconds
	sum ( block_time ) sum_block_time -- Longest any process had to wait for the checkpoint - fractional seconds
from syscheckpoint
group by 1
order by 1 ;
SQL
	my $ref = ifx_request($stmt);
	my @cplist = @{$ref};

	my $dbcheckpoint_maxtime_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_checkpoints_maxtime", 'metric_help'	=> "Informix check points (max cp time)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	my $dbcheckpoint_maxcrtiwait_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_checkpoints_maxcrtiwait_", 'metric_help'	=> "Informix check points (max crit wait)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	my $dbcheckpoint_maxcritsec_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_checkpoints_maxcritsec", 'metric_help'	=> "Informix check points (max crits per second)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	my $dbcheckpoint_maxblocktime_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_checkpoints_maxblocktime", 'metric_help'	=> "Informix check points (max block time)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	my $numcptypes = scalar (@cplist);
	foreach my $cp (@cplist) {
		my $cptype = chomp_ext ($cp->[0]);
		my $numpc = chomp_ext ($cp->[1]);
		my $cpclocktime = chomp_ext ($cp->[2]);
		my $cpmaxtime  =  chomp_ext ($cp->[3]) * 1.0;
		my $cpsumtime  =  chomp_ext ($cp->[4]) * 1.0;
		my $cpmaxcritwait  =  chomp_ext ($cp->[5]) * 1.0;
		my $cpsumcritwait  =  chomp_ext ($cp->[6]) * 1.0;
		my $cpmaxtotalcritwait  =  chomp_ext ($cp->[7]) * 1.0;
		my $cpsumtotalcritwait  =  chomp_ext ($cp->[8]) * 1.0;
		my $cpmaxblocktime  =  chomp_ext ($cp->[9]) * 1.0;
		my $cpsumblocktime  =  chomp_ext ($cp->[10]) * 1.0;

		$totalcheckpoints += $numpc;
		$np->add_perfdata(label => $cptype.'_num_checkpoints',		'value' => $numpc);
		$np->add_perfdata(label => $cptype.'_max_checkpoint_time',	'value' => sprintf ("%.05f", $cpmaxtime));
		$np->add_perfdata(label => $cptype.'_max_crit_waits',		'value' => sprintf ("%.05f", $cpmaxcritwait));
		$np->add_perfdata(label => $cptype.'_max_crit_sec',	'value' => sprintf ("%.05f", $cpmaxtotalcritwait));
		$np->add_perfdata(label => $cptype.'_max_block_time',	'value' => sprintf ("%.05f", $cpmaxblocktime));

		my $status = OK;
		$status = $np->check_threshold('check' => $cpmaxtime, 'warning' => $warn_t, 'critical' => $crit_t);
		$combinedStatus = $status if ($status > $combinedStatus);
		$status = $np->check_threshold('check' => $cpmaxcritwait, 'warning' => $warn_t, 'critical' => $crit_t);
		$combinedStatus = $status if ($status > $combinedStatus);
		$status = $np->check_threshold('check' => $cpmaxcritwait, 'warning' => $warn_s, 'critical' => $crit_s);
		$combinedStatus = $status if ($status > $combinedStatus);
		$status = $np->check_threshold('check' => $cpmaxtotalcritwait, 'warning' => $warn_t, 'critical' => $crit_t);
		$combinedStatus = $status if ($status > $combinedStatus);

		$dbcheckpoint_maxtime_metrics->declare ("ifx_checkpoints_maxtime", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "syscheckpoint", 'env' => $topase_env,});
		$dbcheckpoint_maxcrtiwait_metrics->declare ("ifx_checkpoints_maxcrtiwait_", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "syscheckpoint", 'env' => $topase_env,});
		$dbcheckpoint_maxcritsec_metrics->declare ("ifx_checkpoints_maxcritsec", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "syscheckpoint", 'env' => $topase_env,});
		$dbcheckpoint_maxblocktime_metrics->declare ("ifx_checkpoints_maxblocktime", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "syscheckpoint", 'env' => $topase_env,});
		$dbcheckpoint_maxtime_metrics->set ($cpmaxtime);
		$dbcheckpoint_maxcrtiwait_metrics->set ($cpmaxcritwait);
		$dbcheckpoint_maxcritsec_metrics->set ($cpmaxcritwait);
		$dbcheckpoint_maxblocktime_metrics->set ($cpmaxblocktime);
	}
$np->add_message ($combinedStatus, sprintf "%i kind of checkpoints for a total of %i", $numcptypes, $totalcheckpoints);
	$dbcheckpoint_maxtime_metrics->print_file ('>');
	$dbcheckpoint_maxcrtiwait_metrics->print_file ('>');
	$dbcheckpoint_maxcritsec_metrics->print_file ('>');
	$dbcheckpoint_maxblocktime_metrics->print_file ('>');

}

sub ifx_chunkoffline () {
	my $stmt  = << 'SQL';
select
	name dbspace,
	chknum chunknum,
	fname  device,
	is_offline
from   sysdbspaces d, syschunks c
where d.dbsnum = c.dbsnum and c.is_offline=1
order by dbspace, chunknum ;
SQL
	my $ref = ifx_request($stmt);
	my @chunks = @{$ref};

	my $nbchunks = scalar (@chunks);
	foreach my $chunk (@chunks) {
		; # do nothing for the moment
		print Dumper ($chunk);
	}
	$np->add_message ($nbchunks==0?OK:CRITICAL, sprintf "%i chunks offline", $nbchunks);

}

sub ifx_ioperchunk () {
	my $combinedStatus = OK;
	my $stmt  = << 'SQL';
select
	name dbspace,
	chknum,
	round(  pagesread / ( select sum( pagesread ) from sysmaster:syschktab ) , 2) read_percent,
	round(  pageswritten / ( select sum( pageswritten ) from sysmaster:syschktab ) , 2) write_percent
from    sysmaster:syschktab c, sysmaster:sysdbstab d
where     c.dbsnum = d.dbsnum
order by 1, 2 desc;
SQL
	my $ref = ifx_request($stmt);
	my @databases = @{$ref};
	my $numdb = scalar (@databases);

	my $dbioperchunk_read_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_ioperchunk_read", 'metric_help'	=> "Informix i/o per chunk (read pct)",
		'metric_type'	=> 'counter', 'metric_unit'	=> '%', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	my $dbioperchunk_write_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_ioperchunk_write", 'metric_help'	=> "Informix i/o per chunk (write pct)",
		'metric_type'	=> 'counter', 'metric_unit'	=> '%', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);

	foreach my $db (@databases) {
		my $dbName = chomp_ext ($db->[0]);
		my $chunkID = chomp_ext ($db->[1]);
		my $readpct = chomp_ext ($db->[2]);
		my $writepct = chomp_ext ($db->[3]);

		my $status = OK;
		$np->add_perfdata(label => $dbName.'_read_percent',		'value' => sprintf ("%.02f%%", $readpct));
		$np->add_perfdata(label => $dbName.'_write_percent',		'value' => sprintf ("%.02f%%", $writepct));
		$status = $np->check_threshold('check' => $readpct, 'warning' => $warn_s, 'critical' => $crit_s);
		$combinedStatus = $status if ($status > $combinedStatus);
		$status = $np->check_threshold('check' => $writepct, 'warning' => $warn_s, 'critical' => $crit_s);
		$combinedStatus = $status if ($status > $combinedStatus);

		$dbioperchunk_read_metrics->declare ("ifx_ioperchunk_read", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysmaster", 'env' => $topase_env,});
		$dbioperchunk_write_metrics->declare ("ifx_ioperchunk_write", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysmaster", 'env' => $topase_env,});
		$dbioperchunk_read_metrics->set ($readpct);
		$dbioperchunk_write_metrics->set ($writepct);
	}
	$np->add_message ($combinedStatus, sprintf "%i databases OK", $numdb);
	$dbioperchunk_read_metrics->print_file ('>');
	$dbioperchunk_write_metrics->print_file ('>');
}

sub ifx_stats () {
	my $stmt  = << 'SQL';
select * from sysprofile
where name in (
        "dskreads",
        "bufreads",
        "dskwrites",
        "bufwrites",
        "ovlock",
        "ovuser",
        "ovtrans",
        "buffwts",
        "lockreqs",
        "lockwts",
        "ckptwts",
        "deadlks",
        "lktouts",
        "numckpts",
        "seqscans",
        "totalsorts",
        "memsorts",
        "disksorts",
        "maxsortspace"
        );
SQL
	my $ref = ifx_request($stmt);
	my @stats = @{$ref};
	my $perfdata;

#----------------------------------------------------------------------
	my $dbstats_dskreads_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_dskreads_metrics", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[0]->[1]);
	$dbstats_dskreads_metrics->declare ("ifx_dskreads_metrics", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_dskreads_metrics->set ($perfdata);
	$dbstats_dskreads_metrics->print_file ('>');
	$np->add_perfdata('label' => 'disk_reads',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_bufreads_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_bufreads_metrics", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[1]->[1]);
	$dbstats_dskreads_metrics->declare ("ifx_bufreads_metrics", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_dskreads_metrics->set ($perfdata);
	$dbstats_dskreads_metrics->print_file ('>');
	$np->add_perfdata('label' => 'buf_reads',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_diskwrites_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_diskwrites_metrics", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[1]->[1]);
	$dbstats_diskwrites_metrics->declare ("ifx_diskwrites_metrics", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_diskwrites_metrics->set ($perfdata);
	$dbstats_diskwrites_metrics->print_file ('>');
	$np->add_perfdata('label' => 'disk_writes',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_bufwrites_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_bufwrites_metrics", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[1]->[1]);
	$dbstats_bufwrites_metrics->declare ("ifx_bufwrites_metrics", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_bufwrites_metrics->set ($perfdata);
	$dbstats_bufwrites_metrics->print_file ('>');
	$np->add_perfdata('label' => 'buf_writes',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_overflow_locks_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_overflow_locks_metrics", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[4]->[1]);
	$dbstats_overflow_locks_metrics->declare ("ifx_overflow_locks_metrics", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_overflow_locks_metrics->set ($perfdata);
	$dbstats_overflow_locks_metrics->print_file ('>');
	$np->add_perfdata('label' => 'overflow_locks',			'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_overflow_user_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_overflow_user_metrics", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[5]->[1]);
	$dbstats_overflow_user_metrics->declare ("ifx_overflow_user_metrics", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_overflow_user_metrics->set ($perfdata);
	$dbstats_overflow_user_metrics->print_file ('>');
	$np->add_perfdata('label' => 'overflow_user',			'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_overflow_transactions_metrics = PrometheusMetrics->new (
		'metric_name'	=> "ifx_overflow_transactions_metrics", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[6]->[1]);
	$dbstats_overflow_transactions_metrics->declare ("ifx_overflow_transactions_metrics", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_overflow_transactions_metrics->set ($perfdata);
	$dbstats_overflow_transactions_metrics->print_file ('>');
	$np->add_perfdata('label' => 'overflow_transactions',	'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_buffer_waits = PrometheusMetrics->new (
		'metric_name'	=> "ifx_buffer_waits", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[7]->[1]);
	$dbstats_buffer_waits->declare ("ifx_buffer_waits", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_buffer_waits->set ($perfdata);
	$dbstats_buffer_waits->print_file ('>');
	$np->add_perfdata('label' => 'buffer_waits',			'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_lock_requests = PrometheusMetrics->new (
		'metric_name'	=> "ifx_lock_requests", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[8]->[1]);
	$dbstats_lock_requests->declare ("ifx_lock_requests", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_lock_requests->set ($perfdata);
	$dbstats_lock_requests->print_file ('>');
	$np->add_perfdata('label' => 'lock_requests',			'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_lock_waits = PrometheusMetrics->new (
		'metric_name'	=> "ifx_lock_waits", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[9]->[1]);
	$dbstats_lock_waits->declare ("ifx_lock_waits", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_lock_waits->set ($perfdata);
	$dbstats_lock_waits->print_file ('>');
	$np->add_perfdata('label' => 'lock_waits',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_checkpoints_waits = PrometheusMetrics->new (
		'metric_name'	=> "ifx_checkpoints_waits", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[10]->[1]);
	$dbstats_checkpoints_waits->declare ("ifx_checkpoints_waits", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_checkpoints_waits->set ($perfdata);
	$dbstats_checkpoints_waits->print_file ('>');
	$np->add_perfdata('label' => 'checkpoints_waits',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_deadlocks = PrometheusMetrics->new (
		'metric_name'	=> "ifx_deadlocks", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[11]->[1]);
	$dbstats_deadlocks->declare ("ifx_deadlocks", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_deadlocks->set ($perfdata);
	$dbstats_deadlocks->print_file ('>');
	$np->add_perfdata('label' => 'deadlocks',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_deadlocks_timeouts = PrometheusMetrics->new (
		'metric_name'	=> "ifx_deadlocks_timeouts", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[12]->[1]);
	$dbstats_deadlocks_timeouts->declare ("ifx_deadlocks_timeouts", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_deadlocks_timeouts->set ($perfdata);
	$dbstats_deadlocks_timeouts->print_file ('>');
	$np->add_perfdata('label' => 'deadlocks_timeouts',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_nb_checkpoints = PrometheusMetrics->new (
		'metric_name'	=> "ifx_nb_checkpoints", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[13]->[1]);
	$dbstats_nb_checkpoints->declare ("ifx_nb_checkpoints", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_nb_checkpoints->set ($perfdata);
	$dbstats_nb_checkpoints->print_file ('>');
	$np->add_perfdata('label' => 'nb_checkpoints',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_sequential_scans = PrometheusMetrics->new (
		'metric_name'	=> "ifx_sequential_scans", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[14]->[1]);
	$dbstats_sequential_scans->declare ("ifx_sequential_scans", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_sequential_scans->set ($perfdata);
	$dbstats_sequential_scans->print_file ('>');
	$np->add_perfdata('label' => 'sequential_scans',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_total_sorts = PrometheusMetrics->new (
		'metric_name'	=> "ifx_total_sorts", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[15]->[1]);
	$dbstats_total_sorts->declare ("ifx_total_sorts", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_total_sorts->set ($perfdata);
	$dbstats_total_sorts->print_file ('>');
	$np->add_perfdata('label' => 'total_sorts',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_mem_sorts = PrometheusMetrics->new (
		'metric_name'	=> "ifx_mem_sorts", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[16]->[1]);
	$dbstats_mem_sorts->declare ("ifx_mem_sorts", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_mem_sorts->set ($perfdata);
	$dbstats_mem_sorts->print_file ('>');
	$np->add_perfdata('label' => 'mem_sorts',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_disk_sorts = PrometheusMetrics->new (
		'metric_name'	=> "ifx_disk_sorts", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[17]->[1]);
	$dbstats_disk_sorts->declare ("ifx_disk_sorts", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_disk_sorts->set ($perfdata);
	$dbstats_disk_sorts->print_file ('>');
	$np->add_perfdata('label' => 'disk_sorts',				'value' => $perfdata);
#----------------------------------------------------------------------
	my $dbstats_max_sort_space = PrometheusMetrics->new (
		'metric_name'	=> "ifx_max_sort_space", 'metric_help'	=> "Informix stats (disk reads)",
		'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'		=> $hostaddr, 'env'			=> $topase_env, 'outdir'		=> '/var/spool/nagios/tmpfs/openmetrics/',
		);
	$perfdata = chomp_ext ($stats[18]->[1]);
	$dbstats_max_sort_space->declare ("ifx_max_sort_space", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$dbstats_max_sort_space->set ($perfdata);
	$dbstats_max_sort_space->print_file ('>');
	$np->add_perfdata('label' => 'max_sort_space',				'value' => $perfdata);
#----------------------------------------------------------------------

	$np->add_message (OK, "statistics read");
}


sub ifx_infos () {
	ifx_version ();
	ifx_uptime ();
	ifx_status ();
	ifx_stats ();
}

sub ifx_sharedmemstats () {
	my $stmt = << "SQL";
select sum(seg_size) as total_size, sum(seg_blkused) as total_blkused, sum(seg_blkfree) as total_blkfree,
case
when seg_class=1 then "Resident"
when seg_class =2 then "Virtual"
when seg_class=3 then "Message"
when seg_class=4 then "Buffer"
else
"Inconnu"
end class from syssegments group by seg_class;
SQL
	my $sharedmem_metrics_resident;
	my $sharedmem_metrics_virtual;
	my $sharedmem_metrics_message;
	my $sharedmem_metrics_buffer;
	my %metrics = ( "Resident"	=> $sharedmem_metrics_resident,
					"Virtual"	=> $sharedmem_metrics_virtual,
					"Message"	=> $sharedmem_metrics_message,
					"Buffer"	=> $sharedmem_metrics_buffer,
				);
	my $ref = ifx_request($stmt);
	my @seg_classes = @{$ref};
	foreach my $seg_class (@seg_classes) {
		my $total_size		= chomp_ext($seg_class->[0]);
		my $total_blkused	= chomp_ext($seg_class->[1]);
		my $total_blkfree	= chomp_ext($seg_class->[2]);
		my $class			= chomp_ext($seg_class->[3]);

		$metrics{$class} = PrometheusMetrics->new (
			'metric_name'	=> "ifx_sharemem_metrics_" . lc($class), 'metric_help'	=> "Informix shared memory",
			'metric_type'	=> 'gauge', 'metric_unit'	=> 'B', 'hostaddr'	=> $hostaddr, 'env'	=> $topase_env, 'outdir'	=> '/var/spool/nagios/tmpfs/openmetrics/',
			);

		$metrics{$class}->declare ("ifx_sharedmemstats_totalsize" . lc($class), {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
		$metrics{$class}->set ($total_size);
		$metrics{$class}->print_file ('>');
		$np->add_perfdata('label' => lc($class) . "_" . 'total_size', 'value' => $total_size);

		$metrics{$class}->declare ("ifx_sharedmemstats_totalblkused" . lc($class), {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
		$metrics{$class}->set ($total_blkused);
		$metrics{$class}->print_file ('>');
		$np->add_perfdata('label' => lc($class) . "_" . 'total_blkused', 'value' => $total_blkused);

		$metrics{$class}->declare ("ifx_sharedmemstats_total_blkfree" . lc($class), {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
		$metrics{$class}->set ($total_blkfree);
		$metrics{$class}->print_file ('>');
		$np->add_perfdata('label' => lc($class) . "_" . 'total_blkfree', 'value' => $total_blkfree);

	}
	my $numclasses = scalar(@seg_classes);
	$np->add_message (OK, "$numclasses segment classes");
}

sub ifx_mempoolstats () {
	my $stmt = << "SQL";
select po_name, po_address, po_usedamt as totalsize, po_freeamt as freesize, po_class
from syspools;
SQL

	my $ref = ifx_request($stmt);
	my @pools = @{$ref};
	foreach my $pool (@pools) {
		my $pool_name		= chomp_ext($pool->[0]);
		my $pool_address	= chomp_ext($pool->[1]);
		my $pool_totalsize	= chomp_ext($pool->[2]);
		my $pool_freesize	= chomp_ext($pool->[3]);
		my $pool_class		= chomp_ext($pool->[4]);

		print "$pool_name\t$pool_class\n";
	}
	my $numpools = scalar(@pools);
	$np->add_message (OK, "$numpools memory pools");
}
=cut
$VAR1 = [
	[
		'aqtpool     ',
		'1183785024',
		'7064',
		'1128',
		'2'
	],
	[
		'afpool      ',
		'1157832768',
		'9232',
		'7152',
		'2'
	],
=cut

sub ifx_bigsessions () {
	my $stmt = << "SQL";
SELECT count(a.sid)
FROM sysscblst a, sysrstcb b ,systcblst c, syssqlstat d
WHERE a.address = b.scb AND b.tid = c.tid and d.sqs_sessionid = a.sid and a.memtotal > 100000 and trim(c.name) like 'sqlexec'
SQL

	my $ref = ifx_request($stmt);
	my $session_count = @{$ref}[0]->[0];

	my $metrics = PrometheusMetrics->new (
			'metric_name'	=> "ifx_bigsessions", 'metric_help'	=> "Informix sessions > 100MB",
			'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'	=> $hostaddr, 'env'	=> $topase_env, 'outdir'	=> '/var/spool/nagios/tmpfs/openmetrics/',
			);
	$metrics->declare ("ifx_bigsessions", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$metrics->set ($session_count);
	$np->add_perfdata('label' => 'nb_big_sessions', 'value' => $session_count);
	my $status = $np->check_threshold('check' => $session_count, 'warning' => $warn_s, 'critical' => $crit_s);
	$np->add_message ($status, "$session_count sessions > 100MB");
}

sub ifx_totalmem () {
	my $stmt = << "SQL";
select sum(round(seg_blkused/4000)) as total_used,
sum(round(seg_blkfree/4000)) as total_free from syssegments
SQL
	my $ref = ifx_request($stmt);
	my $total_used = @{$ref}[0]->[0];
	my $total_free = @{$ref}[0]->[1];
	my $percent_used = $total_used/($total_used + $total_free)*100;
	my $metrics = PrometheusMetrics->new (
			'metric_name'	=> "ifx_totalmem", 'metric_help'	=> "Total memory used",
			'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'	=> $hostaddr, 'env'	=> $topase_env, 'outdir'	=> '/var/spool/nagios/tmpfs/openmetrics/',
			);
	$metrics->declare ("ifx_totalmem", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$metrics->set ($percent_used);
	$np->add_perfdata('label' => 'ifx_totalmem', 'value' => $percent_used);
	my $status = $np->check_threshold('check' => $percent_used, 'warning' => $warn_s, 'critical' => $crit_s);
	$np->add_message ($status, sprintf ("Memory used: %.2f%%", $percent_used));

}

sub ifx_non_saved_logs () {
	my $stmt = << "SQL";
select count(uniqid)
from syslogs
where is_used=1
and is_new=0
and is_temp=0
and is_pre_dropped=0
and is_backed_up != 1
SQL
	my $ref = ifx_request($stmt);
	my $non_saved_logs = @{$ref}[0]->[0];
	my $metrics = PrometheusMetrics->new (
			'metric_name'	=> "ifx_non_saved_logs", 'metric_help'	=> "Non saved transactionnal logs",
			'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'	=> $hostaddr, 'env'	=> $topase_env, 'outdir'	=> '/var/spool/nagios/tmpfs/openmetrics/',
			);
	$metrics->declare ("ifx_non_saved_logs", {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
	$metrics->set ($non_saved_logs);
	$np->add_perfdata('label' => 'ifx_non_saved_logs', 'value' => $non_saved_logs);
	my $status = $np->check_threshold('check' => $non_saved_logs, 'warning' => $warn_s, 'critical' => $crit_s);
	$np->add_message ($status, sprintf ("%i non-saved logs", $non_saved_logs));
}


sub ifx_list_logs () {
	my $stmt = << "SQL";
select number,
        size,
        used,
        'is_used:'||is_used,
        'is_current:'||is_current,
        'is_backed_up:'||is_backed_up,
        'is_new:'||is_new,
        'is_archived:'||is_archived,
        'is_temp:'||is_temp,
        'is_pre_dropped:'||is_pre_dropped
from syslogs
order by number
SQL
	my $ref = ifx_request($stmt);

	my @logs = @{$ref};
	foreach my $log (@logs) {
		my $number = $log->[0];
		my $size = $log->[1];
		my $used = $log->[2];
		my $percent = ($used / $size) * 100;

		my $metrics = PrometheusMetrics->new (
				'metric_name'	=> "ifx_transactionnal_log_" . $number, 'metric_help'	=> "Transactionnale log #" . $number,
				'metric_type'	=> 'gauge', 'metric_unit'	=> '', 'hostaddr'	=> $hostaddr, 'env'	=> $topase_env, 'outdir'	=> '/var/spool/nagios/tmpfs/openmetrics/',
				);
		$metrics->declare ("ifx_transactionnal_log_" . $number, {'hostaddr' => $hostaddr, 'hostname' => $hostfqdn, 'nagios_host_id' => $hostID, 'database' => "sysprofile", 'env' => $topase_env,});
		$metrics->set ($percent);
		$np->add_perfdata('label' => "transactionnal_log_" . $number . "_percent_used", 'value' => $percent);
	}
	my $numlogs = scalar (@logs);
	$np->add_message (OK, sprintf ("%i transactionnal logs", $numlogs));
}

###########################################################################

###
# Support functions
###

sub ifx_request($) {
	my $stmt = shift;
	if (my $sth = $dbh->prepare($stmt)) {
		$sth->execute();
		my $ref = $sth->fetchall_arrayref();
		logD (Dumper ($ref));
		return $ref;
	} else {
		$np->add_message (CRITICAL, "Request failed");
		return 0;
	}
}

sub timeoutExit () {
	$np->nagios_exit (CRITICAL, "Informix - Connection timeout !");
}

# Print debug information if $DEBUG > 0
sub logD ($) {
	my $msg = shift;
	return if not $DEBUG;
	if ($LOGTOFILE) {
		open (my $logfh, ">>", "/var/log/nagios/plugin.log");
		print $logfh "[DEBUG] ".$msg."\n";
		close $logfh;
	} else {
		print STDERR "[DEBUG] ".$msg."\n";
	}
}

sub logInfo ($) {
	my $msg = shift;
	if ($LOGTOFILE) {
		open (my $logfh, ">>", "/var/log/nagios/plugin.log");
		print $logfh "[INFO] ".$msg."\n";
		close $logfh;
	} else {
		print STDERR "[INFO] ".$msg."\n";
	}
}

sub uom2megabytes($$) {
	my ($value, $uom) = @_;

	$uom =~ s/^ +//;
	$uom =~ s/ +$//;

	if ( $uom eq 'KB') {
		return $value/1024.0;
	} elsif ($uom eq 'MB') {
		return $value;
	} elsif ($uom eq 'B'){
		return $value/1048576.0;
	} elsif ($uom eq 'GB'){
		return $value*1024;
	}
}

sub chomp_ext($) {
	my $str = shift;

	chomp($str);
	$str =~ s/\s+$//g;
	$str =~ s/^\s+//g;
	return $str;
}










=pod

=cut
