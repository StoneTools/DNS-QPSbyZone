#!/usr/bin/env perl

use warnings;
use strict;
use Config::Simple;
use Getopt::Long;
use Time::Local;
use Text::CSV_XS;
use Data::Dumper;

#Import DynECT handler
use FindBin;
use lib "$FindBin::Bin/DynECT";  # use the parent directory
require DynECT::DNS_REST;


#Create config reader
my $cfg = new Config::Simple();
# read configuration file (can fail)
$cfg->read('config.cfg') or die $cfg->error();

#dump config variables into hash for later use
my %configopt = $cfg->vars();
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

my $csv = Text::CSV_XS->new ( { binary => 1 } ) or die "Cannot use CSV: ".Text::CSV->error_diag ();

#API login
my $dynect = DynECT::DNS_REST->new;
$dynect->login( $apicn, $apiun, $apipw) or
	die $dynect->message;

my ($day, $month, $year) = ( gmtime() )[3 .. 5];
my $endtime = timegm( 0, 0, 0, $day, $month, $year );
my $start_ts = $endtime - 2419200; #604800;
my %api_param = ( breakdown => 'zones');
my $rep_day = 0;
my %week1query;
my %week2query;
my %week3query;
my %week4query;
my %monthquery;

while ( $start_ts < $endtime ) {
	$api_param{ 'start_ts' } = $start_ts;
	$api_param{ 'end_ts' } = $start_ts + 86399;		#just shy of a full day
	$dynect->request ( '/REST/QPSReport', 'POST', \%api_param);
	print Dumper $dynect->result;

	my @lines = split /\n/, $dynect->result->{'data'}{'csv'};
	foreach my $line ( @lines ) {
		$csv->parse( $line );
		my @fields = $csv->fields;
		next if $fields[0] eq 'Timestamp';
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


	$start_ts  += 86400;
	$rep_day++;
	sleep 1;
}

foreach my $zone ( keys %monthquery ){
	my @csvprint = ( $zone, 0, 0, 0, 0 );
	$csvprint[1] = ninefive( $week1query{ $zone } ) if ( exists $week1query{ $zone } );
	$csvprint[2] = ninefive( $week2query{ $zone } ) if ( exists $week2query{ $zone } );
	$csvprint[3] = ninefive( $week3query{ $zone } ) if ( exists $week3query{ $zone } );
	$csvprint[4] = ninefive( $week4query{ $zone } ) if ( exists $week4query{ $zone } );
	$csvprint[5] = ninefive( $monthquery{ $zone } );
	print Dumper \@csvprint;
}

# Close csv file
#if($opt_file ne "")
#{
#close $fh or die "$!";
#print "CSV file: $opt_file written sucessfully.\n";
#}

#api logout
$dynect->logout;



sub ninefive {
	my $arrref = shift @_;
	my @queries = sort {$a <=> $b} @$arrref;
	#This round towards zeo.  Normally for 95% you would round up but the array index 
	#starts at 0 effectively giving a +1 to the calculaiton
	my $ninefive = int( scalar( @queries )  * 0.95 ) ;

	#Truncate to 3 signifigant digits
	my $qps = int( ($queries[$ninefive] / 300 ) * 1000 ) / 1000;

	return $qps;
}
