# NOTE: Right now this program looks for days when the Wolf number reported is zero or the
# Ra is zero, and sets them to zero rather than trying to take the log of zero. This is 
# probably not the right way to handle it (see Matthew's email). Probably, I should just 
# ignore those days. Check with Rodney. Also, look into taking into account the seeing or
# other factors that Rodney mentions in a recent email.

#!/usr/bin/perl -w

# This program is used for computing the k-factors for solar observers
# Author: Sara J. Beck (with help from Matthew Templeton)
# Latest revision: 3 January 2013 

# perl modules
use DBI;
use Astro::Time;

#initialize variables
my $outfile_name = "new_k-factors.txt";
my ($start_jd, $end_jd, %ra_number, $ra_number, @observer_list, @wolf_number, $last_ra_date);

# MySQL parameters
#$db=getdbh("solar","db.aavso.org", "sara", "12vkxi5");
$db=getdbh("solar","db.aavso.org", "solarobs", "TheSunIsBright!");

print "\n*** K-factor calculator ***\n";

# Get the start date (calendar date is converted to JD)
print "\nPlease enter the start date for period (MM-DD-YYYY):\n";
chomp(my $start_date = <STDIN>);
my ($month, $day, $year) = split /-/, $start_date;
$start_jd=mjd2jd(cal2mjd($day,$month,$year,0.5));
#print "$start_jd\n";

# Get the end date (calendar date is converted to JD). Also check to see that end
# date is at least 100 days past the start date
$n = 0; $end_jd = 0; $range = 0;

# Query for getting the last JD entered into the Ra table:
$select_last_ra_date_query = "SELECT jd from sunspot_counts order by jd DESC limit 1";
$st_select_last_ra_date = $db->prepare($select_last_ra_date_query) or die "Error:".$db->errstr."\n"; 

# Gets the end date for the query (with a couple checks)
do {
	$last_ra_date = &get_last_ra_date();
	($day, $month, $year, $ut) = mjd2cal(jd2mjd($last_ra_date));
	if ($n == 0) {
		print "\nPlease enter the end date for period (MM-DD-YYYY):\n";
		print "(No later than $month-$day-$year)\n";
	} else {
		print "\nThe end date has to be at least 100 later than the start date\n";
		print "and no later than $month-$day-$year. Please try again:\n";
	} 
	chomp(my $end_date = <STDIN>);
	($month, $day, $year) = split /-/, $end_date;
	$end_jd=mjd2jd(cal2mjd($day,$month,$year,0.5));
	
	if ($end_jd > $last_ra_date) {
		$end_jd = 0;
	}
	$n++;
	$range = $end_jd - $start_jd;
} while ($range < 100);
print "\n";

# Query for getting a list of all the observers with 100 or more observations within the 
# period specified.
$select_observers_query = "SELECT obs, count(*) as count from sun_data where date >= ? 
and date <= ? and revised = 0 group by obs having count >= 100 order by obs";
$st_select_observers = $db->prepare($select_observers_query) or die "Error:".$db->errstr."\n"; 

# Query for getting all the Wolf numbers and JDs for a given observer during the 
# period specified.
$select_wolf_numbers_query = "SELECT W, date from sun_data where obs = ? and date >= ? 
and date <= ? and revised = 0 order by date";
$st_select_wolf_numbers = $db->prepare($select_wolf_numbers_query) or die "Error:".$db->errstr."\n"; 

# Query for getting a list of all the Ra numbers within the period specified.
$select_ra_query = "SELECT count, jd from sunspot_counts where jd >= ? and jd <= ? 
order by jd";
$st_select_ra_numbers = $db->prepare($select_ra_query) or die "Error:".$db->errstr."\n"; 

# Query for getting a list of all old k-factors for each observer.
$select_old_k_query = "SELECT k from sun_obsconst where obs = ? and revised = 0";
$st_select_old_k = $db->prepare($select_old_k_query) or die "Error:".$db->errstr."\n"; 

# Run query to get list of observers and put list into an array
&get_observer_list($start_jd, $end_jd);

# Run query to get list of Ra numbers for the period and put them in a hash
&get_ra_numbers($start_jd, $end_jd);

# Go through observers one by one and compute their k-factor...
&print_record("observer\tK-factor\n");
foreach $observer (@observer_list) {
	$logK=0; $logRA=0; $logWolf=0; #re-set variables
	@wolf_number = (); 
	$obs_name = $observer -> {A};
	$observation_count = $observer -> {B};
	&get_wolf_numbers($obs_name, $start_jd, $end_jd); #gets data submitted by this observer
	foreach $wolf_number (@wolf_number) { 
		$observed_wolf = $wolf_number -> {A}; #Wolf number
		$date = $wolf_number -> {B}; #associated date
		if ($ra_number{$date} != 0) {  #to prevent taking log of zero
			$logRA = $logRA + &log10($ra_number{$date}); #gets log of Ra for that date
		} else {
			$logRA = $logRA + 0.1; #If Ra is zero assume log10(Ra) = 0.1
		} 
		if ($observed_wolf != 0) {  #to prevent taking log of zero
			$logWolf = $logWolf + &log10($observed_wolf); #gets Wolf number for the same date
		} else {
			$logWolf = $logWolf + 0.1; #If the Wolf number is zero assume log10(W) = 0.1
		}
           # printf("%9.0f|% 4s|% 3d|% 3d\n", $date, $obs_name, $observed_wolf, $logRA);
	} 
	$logK = ($logRA - $logWolf)/$observation_count;
	$k_factor = sprintf("%.3f", 10**$logK);  #rounds value to 3 decimal places
	$old_k = &get_old_k($obs_name); #gets old k-factor from sun_obsconst
	print "$obs_name:\t$k_factor ($observation_count obs)\told k-factor:\t$old_k\n";
	&print_record ("$obs_name\t$k_factor\n");
}

# Runs a sql query to get a list of all observers with 100 or more observations in the
# specified range. The variable returned contains both the observer's initials and the
# number of observations made during the period.
sub get_observer_list {

	$start_jd = $_[0];
	$end_jd = $_[1];

	$st_select_observers -> execute("$start_jd", "$end_jd") 
		or die "Execution failed: ".$db->errstr."\n";

	while(($a,$b) = $st_select_observers -> fetchrow_array){
		$observer_list = {
			A => $a,
			B => $b
		};
		push (@observer_list, $observer_list);
	}
	$st_select_observers->finish();
	return @observer_list;
}

# Runs a sql query to get a hash of all the Ra numbers in the specified range. The key
# is the date (JD) and the value is the Ra number. 
sub get_ra_numbers {

	$start_jd = $_[0];
	$end_jd = $_[1];

	$st_select_ra_numbers -> execute("$start_jd", "$end_jd") 
		or die "Execution failed: ".$db->errstr."\n";

	while(($a,$b) = $st_select_ra_numbers -> fetchrow_array){
		$ra_number{$b} = $a;
	}
	$st_select_ra_numbers->finish();
	return %ra_number;
}

# Runs a sql query to get all the wolf numbers for a given observer during the date
# range specified
sub get_wolf_numbers {

	$obs = $_[0];
	$start_jd = $_[1];
	$end_jd = $_[2];

	$st_select_wolf_numbers -> execute("$obs", "$start_jd", "$end_jd") 
		or die "Execution failed: ".$db->errstr."\n";

	while(($a,$b) = $st_select_wolf_numbers -> fetchrow_array){
		$wolf_number = {
			A => $a,
			B => $b
		};
		push (@wolf_number, $wolf_number);
	}
	$st_select_wolf_numbers->finish();
	return @wolf_number;
}

# Runs a sql query to find the last Ra entered in the table
sub get_last_ra_date {

	$st_select_last_ra_date -> execute() or die "Execution failed: ".$db->errstr."\n";

	$last_ra_date = ($st_select_last_ra_date -> fetchrow_array);
	$st_select_last_ra_date->finish();
	return $last_ra_date;
}

#Runs a sql query to get their "old" K-factors from the sun_obsconst table
sub get_old_k {

	$obs = $_[0];
	
	$st_select_old_k -> execute("$obs") or die "Execution failed: ".$db->errstr."\n";
	
	$old_k = ($st_select_old_k -> fetchrow_array);
	$st_select_old_k->finish();
	return $old_k;
}

# Gets the base 10 logarithm
sub log10 {
	my $n = shift;
	return log($n)/log(10);
}

# Matthew's subroutine for creating the database connection
sub getdbh {

  # getdbh -- a subroutine that returns a MySQL database handle for a
  # user-supplied database name.
  #
  # calling syntax:  $dbh=getdbh($database_name);
  #
  #     $dbh == database handle
  #     $database_name == name of MySQL db you wish to connect to.
  #
  # Author: M. Templeton, AAVSO, 2009 December 10

	$dbname=$_[0];
	$host=$_[1];
	$user=$_[2];
	$pass=$_[3];
	$dbh=DBI->connect("DBI:mysql:$dbname;host=$host;user=$user;password=$pass");
	return $dbh;
}

# This subroutine simply prints whatever is passed to it to a log file.
sub print_record {
	my $note = $_[0];
	open(ASDF, ">>$outfile_name");
	print ASDF "$note";
	close(ASDF);
}

