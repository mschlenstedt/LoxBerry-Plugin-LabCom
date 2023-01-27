#!/usr/bin/perl

# Grabber for overwriting data by WeatherUnderground data

# Copyright 2016-2019 Michael Schlenstedt, michael@loxberry.de
# 			Christian Fenzl, christian@loxberry.de
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use warnings;

##########################################################################
# Modules
##########################################################################

use LoxBerry::System;
use LoxBerry::Log;
use LoxBerry::IO;
use LoxBerry::JSON;
use LWP::UserAgent;
use Getopt::Long;
use Data::Dumper;
use Net::MQTT::Simple;
use Time::HiRes qw ( sleep );
use experimental 'smartmatch';

##########################################################################
# Read Settings
##########################################################################

# Version of this script
my $version = LoxBerry::System::pluginversion();

# Globals
my $url = "https://backend.labcom.cloud/graphql";
my $account;
my $token;
my $logfile;
my $test;
my $verbose;
my $force;
my $accountfilter;
my $lasttimestamp;
my $received;

# Commandline options
# CGI doesn't work from other CGI skripts... :-(
#my $cgi = CGI->new;
#my $q = $cgi->Vars;
GetOptions ('verbose' => \$verbose,
            'token=s' => \$token,
            'account=s' => \$account,
            'logfile=s' => \$logfile,
            'test' => \$test,
            'force' => \$force);

# Create a logging object
my $log;
if ( $logfile ) {
	my $fulllogfile = "$lbplogdir" . "/" . $logfile;
	$log = LoxBerry::Log->new ( 	
		package => 'labcom',
		name => 'labcomgrabber',
		filename => "$fulllogfile",
	);
} else {
	$log = LoxBerry::Log->new ( 	
		package => 'labcom',
		name => 'labcomgrabber',
		logdir => "$lbplogdir",
	);
}

if ($verbose || $test || $force) {
	$log->stdout(1);
	$log->loglevel(7);
}

LOGSTART "LabCom Cloud Grabber process started";
LOGDEB "This is $0 Version $version";

# Read config
my $jsoncfg = LoxBerry::JSON->new();
my $cfg = $jsoncfg->open(filename => "$lbpconfigdir/config.json");
$accountfilter = "(id: [$cfg->{'accountid'}])";

# Read tmp memory file
#my $jsonmem = LoxBerry::JSON->new();
#my $mem = $jsonmem->open(filename => "/dev/shm/labcom_mem.json", writeonclose => 1);

# Commandline options
if (!$token) {
	$token = $cfg->{'token'};
}
if (!$token) {
	LOGCRIT "Token missing";
	exit 2;
}

if (!$account) {
	$account = $cfg->{'accountid'};
}
if ($account) {
	$accountfilter = "(id: [$account])";
} else {
	$account = "0";
	$accountfilter = "";
}

my $query = "{\"query\": \"{ CloudAccount {email last_change_time Accounts $accountfilter {forename surname Measurements {value unit timestamp parameter scenario device_serial operator_name ideal_low ideal_high}}} }\"}";

LOGINF "Fetching Data from $url";
my $ua = new LWP::UserAgent;
my $resp = $ua->post(	$url,
       			'Content-Type' => 'application/json',
			'Authorization' => "$token",
		       	'Content' => $query
	       	);
my $raw = $resp->decoded_content();

# Check status of request
my $urlstatus = $resp->status_line;
my $urlstatuscode = substr($urlstatus,0,3);
LOGDEB "Status: $urlstatus";
if ($urlstatuscode ne "200") {
	LOGCRIT "Failed to fetch data from $url\. Status Code: $urlstatuscode";
	exit 2;
} else {
	LOGOK "Data fetched successfully from $url";
	LOGDEB "Received data (raw) is:";
	LOGDEB "$raw";
}

# Decode JSON response from server
my $json = decode_json( $raw );

# If in Test mode
if ($test) {
	LOGDEB "Received data:";
	LOGDEB "$raw";
	exit;
}

# Parse data and send via MQTT
my $mqtt;

# Allow unencrypted connection with credentials
$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;
#$cfg->{'brokerport'} = "1883" if !$cfg->{'brokerport'};

# From LoxBerry 3.0 on, we have MQTT onboard
my $mqttcred = LoxBerry::IO::mqtt_connectiondetails();
$cfg->{'brokeruser'}  = $mqttcred->{brokeruser};
$cfg->{'brokerpassword'} = $mqttcred->{brokerpass};
$cfg->{'broker'} = $mqttcred->{brokerhost};
$cfg->{'brokerport'} = $mqttcred->{brokerport};

# Connect to MQTT Broker
LOGDEB "Connecting to MQTT Broker...";
if ($cfg->{'broker'} && $cfg->{'brokerport'}) {
	$mqtt = Net::MQTT::Simple->new( "$cfg->{'broker'}:$cfg->{'brokerport'}");
} else {
	LOGERR "MQTT Broker seems not to be configured. Giving up.";
	exit 2;
}

# Use Auth
if( $cfg->{'brokeruser'} && $cfg->{'brokerpassword'} ) {
	$mqtt->login($cfg->{'brokeruser'}, $cfg->{'brokerpassword'});
}

# Plugindata
my $now = time;
$mqtt->retain("$cfg->{'topic'}" . "/plugin/lastcall", "$now");
$mqtt->retain("$cfg->{'topic'}" . "/plugin/lastcall_human", scalar(localtime($now)));

# Check if account has changed since last run
$received = "0";
$lasttimestamp = "0";
$mqtt->subscribe("$cfg->{'topic'}" . "/CloudAccount/last_change_time", \&received);
for (my $i=0;$i<10;$i++) {
	last if ($received);
	$mqtt->tick();
	sleep (0.1);
}
$mqtt->unsubscribe("$cfg->{'topic'}" . "/CloudAccount/last_change_time");
if (!$force && $lasttimestamp && $lasttimestamp >= $json->{'data'}->{'CloudAccount'}->{'last_change_time'}) {
	LOGINF "Your account data hasn't changed since last call. Nothing to do.";
	$mqtt->disconnect();
	exit;
}

# Parse Cloud Account data
$mqtt->retain("$cfg->{'topic'}" . "/CloudAccount/last_change_time", $json->{'data'}->{'CloudAccount'}->{'last_change_time'});
$mqtt->retain("$cfg->{'topic'}" . "/CloudAccount/email", $json->{'data'}->{'CloudAccount'}->{'email'});
$mqtt->retain("$cfg->{'topic'}" . "/CloudAccount/last_change_time_human", scalar(localtime($json->{'data'}->{'CloudAccount'}->{'last_change_time'})));

# Parse Accounts
foreach my $account ( @{$json->{data}->{'CloudAccount'}->{'Accounts'}} ) {

	my $accountname = "$account->{'forename'}" . "_" . "$account->{'surname'}";
	LOGINF "Parsing Account $accountname";

	# Parse Measurements
	foreach my $measurement ( @{$account->{'Measurements'}} ) {
		my $send;
		# Clean values for topic
		my $scenario = $measurement->{'scenario'};
		$scenario =~ s/\s+/_/g;
		my $parameter = $measurement->{'parameter'};
		$parameter =~ s/\s+/_/g;
		LOGDEB "--> Found Measurement $scenario/$parameter";

		# Check if this measurement already exist in broker
		$received = "0";
		$lasttimestamp = "0";
		$mqtt->subscribe("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/timestamp", \&received);
		for (my $i=0;$i<10;$i++) {
			last if ($received);
			$mqtt->tick();
			sleep (0.1);
		}
		$mqtt->unsubscribe("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/timestamp");
		# Check if current measurement is newer than the one from the broker. Send to broker if newer or equal (caching is done in MQTT Gateway)
		if ( $lasttimestamp && $lasttimestamp > $measurement->{'timestamp'} ) {
			LOGDEB "Existing measurement from Timestamp $lasttimestamp is newer than found measurement form Timestamp $measurement->{'timestamp'}. Skipping.";
			next;
		} else {
			LOGDEB "Found measurement from Timestamp $measurement->{'timestamp'} is newer (or equal) than existing measurement from Timestamp $lasttimestamp. Sending.";
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/scenario", "$measurement->{'scenario'}");
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/parameter", "$measurement->{'parameter'}");
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/timestamp", "$measurement->{'timestamp'}");
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/timestamp_human", scalar(localtime($measurement->{'timestamp'})));
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/value", "$measurement->{'value'}");
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/device_serial", "$measurement->{'device_serial'}");
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/unit", "$measurement->{'unit'}");
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/operator_name", "$measurement->{'operator_name'}");
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/ideal_low", "$measurement->{'ideal_low'}");
			$mqtt->retain("$cfg->{'topic'}" . "/" . $accountname . "/" . $scenario . "/" . $parameter . "/ideal_high", "$measurement->{'ideal_high'}");
		}
	}
	
}

# Disconnect
$mqtt->disconnect();
exit;

# Sub: Get value from Broker
sub received
{
	$received = 1;
	my ($topic, $message) = @_;
	LOGDEB "--> Incoming message on topic $topic is: $message";
    	if ($message) {
    		$lasttimestamp = $message;
	}
}

# Always close log
END {
	LOGEND;
}

