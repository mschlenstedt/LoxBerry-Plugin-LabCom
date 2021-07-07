#!/usr/bin/perl

# Copyright 2019-2020 Michael Schlenstedt, michael@loxberry.de
#                     Christian Fenzl, christian@loxberry.de
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


##########################################################################
# Modules
##########################################################################

use CGI;
use LoxBerry::System;
use warnings;
use strict;

##########################################################################
# Variables
##########################################################################

# Read Form
my $cgi = CGI->new;
my $q = $cgi->Vars;

print $cgi->header(
		-type => 'text/plain',
		-charset => 'utf-8',
		-status => '200 OK',
);	

my $output =  `$lbpbindir/labcomgrabber.pl verbose=1 test=1 token=$q->{'token'} account=$q->{'account'} 2>&1`;
print $output;

exit;
