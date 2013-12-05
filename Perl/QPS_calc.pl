#!/usr/bin/env perl


use warnings;
use strict;
use Config::Simple;
use Getopt::Long;
use Time::Local;
use Text::CSV_XS;
use DateTime;

#Import DynECT handler
use FindBin;
use lib $FindBin::Bin;  # use the parent directory
require DynECT::DNS_REST;


#Create config reader
my $cfg = new Config::Simple();
# read configuration file (can fail)
$cfg->read('config.cfg') or die $cfg->error();

my $opt_startymd;
my $opt_days;
my $opt_help;
my $opt_file;

#grab CLI options
GetOptions( 
	'start=s'	=>	\$opt_startymd,
	'days=s'	=>	\$opt_days,
	'file=s'	=>	\$opt_file,
	'help'		=>	\$opt_help,
);

if ( $opt_help ) {
	print "Options:\n";
	print "\t-h --help\tShow this help message and exit\n";
	print "\t-s --start\tDefine an start date for the data range in YYYY-MM-DD format\n";
	print "\t-d --days\tDefine total number of days to include in date range\n";
	print "\t-f --file\tFilename to write csv report\n";
	exit;
}

#dump config variables into hash
my %configopt = $cfg->vars();

#simple error checking
if ( ( $configopt{'cn'} eq 'custname' ) || ( $configopt{'un'} eq 'username' ) ) {
	print "Please update config.cfg configuration file with account information for API access\n";
	exit;
}

my $apicn = $configopt{'cn'} or do {
	print "Customer Name required in config.cfg for API login\n";
	exit;
};

my $apiun = $configopt{'un'} or do {
	print "User Name required in config.cfg for API login\n";
	exit;
};

my $apipw = $configopt{'pw'} or do {
	print "User password required in config.cfg for API login\n";
	exit;
};

#initiliaze csv object
my $csv = Text::CSV_XS->new ( { binary => 1 } ) or die "Cannot use CSV: " . Text::CSV->error_diag ();


my $dt_start;
#Create datetime object for today (defaults to UTC)
if ( $opt_startymd ) {
	if ( $opt_startymd =~ /(\d{4})-(\d{2})-(\d{2})/ ) {
		$dt_start = DateTime->new( year => $1, month => $2, day => $3 );
		my $dt_comp = DateTime->today;
		if ( $dt_start > $dt_comp ) {
			print "Start date must be in the past.  See --help for additional information\n";
			exit;
		}

		#90 days of stats is inclusive with today, subtract only 89 days
		$dt_comp->subtract( days => 89 );
		#truncate to 90 days of stats if over
		$dt_start = $dt_comp->clone if( $dt_start < $dt_comp  );
	}
	else {
		print "Invalid date format, use --help for more information\n";
		exit;
	}
}
else {
	$dt_start = DateTime->today->subtract( days => 89 );
}

my $range;
#Get the star of the range
if ( $opt_days) {
	$range = int( $opt_days );
}
else {
	$range = 90;
}

#create scoped region to prevent keeping extraneous DT object
{
	my $dt_end = $dt_start->clone->add( days => $range );
	my $dt_comp = DateTime->today;
	if ( $dt_end > $dt_comp ) {
		my $dt_dur =  $dt_comp->delta_days( $dt_start );
		#plus 1 to be inclusive of any data today (since UTC midnight)
		$range = $dt_dur->delta_days + 1;
	}
}

#initilize DynECT API handler module
my $dynect = DynECT::DNS_REST->new;
#API login
$dynect->login( $apicn, $apiun, $apipw) 
	or die $dynect->message;

#API Paramater hash
my %api_param = ( breakdown => 'zones');
my %zone_store;

#header building for CSV
my @csvhead = ( 'Zones' );

for ( my $i = 0; $i<$range; $i++ ) {
	push ( @csvhead, $dt_start->ymd('-'));

	#set start timestamp to start of that day
	$api_param{ 'start_ts' } = $dt_start->epoch();
	#advance to next day here to avoid doubling up on the calculation
	$dt_start->add( days => 1 );
	#subtraction 1 second and set that as the end time stamp
	$api_param{ 'end_ts' } = $dt_start->clone->subtract( seconds => 1 )->epoch();
	$dynect->request ( '/REST/QPSReport', 'POST', \%api_param)
		or die $dynect->message;

	#Break apart response CSV on line breaks to hand to CSV handler
	my @lines = split /\n/, $dynect->result->{'data'}{'csv'};

	#storage of that day's data
	my %day_store;
	foreach my $line ( @lines ) {
		$csv->parse( $line );
		my @fields = $csv->fields;
		#skip header line
		next if $fields[0] eq 'Timestamp';

		#store the largest value for that day ( looking for the peak )
		if ( exists $day_store{ $fields[1] } ) {
			$day_store{ $fields[1] } = $fields[2]  if ( $day_store{ $fields[1] } < $fields[2] );
		}
		else {
			$day_store{ $fields[1] } = $fields[2];
		}
	}

	#add in a zero for any zones we know about but didn't see today	
	foreach my $zone ( keys %zone_store ) {
		unless ( exists $day_store{ $zone } ) {
			push @{ $zone_store{ $zone } } , 0;
		}
	}

	#add in data for all zones we did see today
	foreach my $zone ( keys %day_store ) { 
		push @{ $zone_store{ $zone } } , $day_store{ $zone };
	}
	
	#brief sleep before making next API call
	sleep 1;
	}

#create file for writing
my $filename;
if ( $opt_file ) {
	$filename = $opt_file;
}
else {
	$filename = 'report.csv'
}

open my $fh, '>', $filename;
#print headers
$csv->print( $fh, \@csvhead );
print $fh "\n";
foreach my $zone ( keys %zone_store ){
	#create default values
	my $csvlen = scalar @csvhead;
	my @csvprint = (0)x$csvlen;
	$csvprint[0] = $zone;
	#subtract 1 to get accurate pointer (accounting for 0th  slot)
	my $ptr = $csvlen - 1;
	#iterate easch array backwards

	my $query = pop @{ $zone_store{ $zone } };
	while ( defined $query ) {
		#divide by 300 seconds, move the decimal to expose the 1000th place
		#Add 0.5 to accurately round then int to truncate
		#Divide by 1000 to replace decimal
		$query = (int((($query / 300) * 1000) + 0.5 ))/1000 ;

		$csvprint[$ptr] = $query;
		$ptr--;
		$query = pop @{ $zone_store{ $zone } };
	}

	#print that zone to file
	$csv->print( $fh, \@csvprint );
	print $fh "\n";
}

#close file handle
close $fh;


#logout of the API to be nice
$dynect->logout;

#subroutine to handle the 95th percentile calculations
#currently unused
sub ninefive {
	#grab reference to array from paramaters
	my $arrref = shift @_;
	#sort array numerically ascending
	my @queries = sort {$a <=> $b} @$arrref;
	#This round towards zeo.  Normally for 95% you would round up but the array index 
	#starts at 0 effectively giving a +1 to the calculaiton
	my $ninefive = int( scalar( @queries )  * 0.95 ) ;

	#Truncate to 3 signifigant digits
	my $qps = int( ($queries[$ninefive] / 300 ) * 1000 ) / 1000;

	return $qps;
}
