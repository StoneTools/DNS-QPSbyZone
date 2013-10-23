#!/usr/bin/env perl

use warnings;
use strict;
use Config::Simple;
use Getopt::Long;
use Time::Local;
use Text::CSV_XS;

#Import DynECT handler
use FindBin;
use lib "$FindBin::Bin/DynECT";  # use the parent directory
require DynECT::DNS_REST;


#Create config reader
my $cfg = new Config::Simple();
# read configuration file (can fail)
$cfg->read('config.cfg') or die $cfg->error();

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

#initilize DynECT API handler module
my $dynect = DynECT::DNS_REST->new;
#API login
$dynect->login( $apicn, $apiun, $apipw) or
	die $dynect->message;

#get current GMT time and turn that beck into GMT midnight
my ($day, $month, $year) = ( gmtime() )[3 .. 5];
my $endtime = timegm( 0, 0, 0, $day, $month, $year );

#Set start run time to 28 days ago
my $start_ts = $endtime - (86400 * 28);
#API Paramater hash
my %api_param = ( breakdown => 'zones');

#Data storage variables
my $rep_day = 0;
my %week1query;
my %week2query;
my %week3query;
my %week4query;
my %monthquery;

#process until we have passed the end time
while ( $start_ts < $endtime ) {
	$api_param{ 'start_ts' } = $start_ts;
	#process just full of a full day to avoid possible data retention issues with stats
	$api_param{ 'end_ts' } = $start_ts + 86399;
	$dynect->request ( '/REST/QPSReport', 'POST', \%api_param);

	#Break apart response CSV on line breaks to hand to CSV handler
	my @lines = split /\n/, $dynect->result->{'data'}{'csv'};

	foreach my $line ( @lines ) {
		$csv->parse( $line );
		my @fields = $csv->fields;
		#skip header line
		next if $fields[0] eq 'Timestamp';

		#process retrieved data into buckets
		if ( $rep_day < 7 ) {
			push @{$week1query{$fields[1]}}, $fields[2];
		}
		elsif ( $rep_day < 14 ) {
			push @{$week2query{$fields[1]}}, $fields[2];
		}
		elsif ( $rep_day < 21 ) {
			push @{$week3query{$fields[1]}}, $fields[2];
		}
		elsif ( $rep_day < 28 ) {
			push @{$week4query{$fields[1]}}, $fields[2];
		}
		push @{$monthquery{$fields[1]}}, $fields[2];
	}

	#advance to next day
	$start_ts  += 86400;
	$rep_day++;
	#brief sleep before making next API call
	sleep 1;
}

#create file for writing
open my $fh, '>', 'report.txt';
#print headers
my @headers = ( 'Zone', 'Week1', 'Week2', 'Week3', 'Week4', 'Month' );
$csv->print( $fh, \@headers);
print $fh "\n";


foreach my $zone ( keys %monthquery ){
	#create default values
	my @csvprint = ( $zone, 0.00, 0.00, 0.00, 0.00 );
	#assign value in array form each week if it exists
	$csvprint[1] = ninefive( $week1query{ $zone } ) if ( exists $week1query{ $zone } );
	$csvprint[2] = ninefive( $week2query{ $zone } ) if ( exists $week2query{ $zone } );
	$csvprint[3] = ninefive( $week3query{ $zone } ) if ( exists $week3query{ $zone } );
	$csvprint[4] = ninefive( $week4query{ $zone } ) if ( exists $week4query{ $zone } );
	$csvprint[5] = ninefive( $monthquery{ $zone } );
	#print that zone to file
	$csv->print( $fh, \@csvprint );
	print $fh "\n";
}

#logout of the API to be nice
$dynect->logout;

#subroutine to handle the 95th percentile calculations
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
