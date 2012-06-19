#!perl

# CVS: $Id: ljpms2.pl,v 1.4 2007/10/02 19:00:00 sasha Exp $
# Author: Alexander Nikolaev <sasha_nikolaev@yahoo.com>
# 

#perl2exe_info FileDescription=Utility for Livejournal.com backup and post security level manipulation
#perl2exe_info ProductName=LJPMS
#perl2exe_info ProductVersion=1.3.0.0
#perl2exe_info FileVersion=1.3.0.0
#perl2exe_info LegalCopyright=GPL
#perl2exe_info CompanyName=Alexander Nikolaev, sasha_nikolaev@yahoo.com

#perl2exe_include "utf8.pm"
#perl2exe_include "unicore/lib/gc_sc/Word.pl"
#perl2exe_include "unicore/lib/gc_sc/Digit.pl"
#perl2exe_include "unicore/lib/gc_sc/SpacePer.pl"
#perl2exe_include "unicore/To/Lower.pl"
#perl2exe_include "unicore/lib/gc_sc/Cntrl.pl"
#perl2exe_include "unicore/lib/gc_sc/ASCII.pl"
#perl2exe_include "unicore/To/Fold.pl" 
#perl2exe_bundle "C:/bin/Perl/site/lib/XML/SAX/ParserDetails.ini"

# http://perl-xml.sourceforge.net/faq/#parserdetails.ini
# "could not find ParserDetails.ini"
# 1. ppm install http://theoryx5.uwinnipeg.ca/ppms/XML-SAX.ppd
# 2. ppm install XML::SAX::Expat
# 3. edit \Perl\site\lib\XML\SAX\ParserDetails.ini:
#   [XML::SAX::Expat]
#   http://xml.org/sax/features/namespaces = 1
# 

#
# cyrillic encodings language pack for XML::Parser:
# http://uucode.com/xml/perl/enc.zip
#


# require recent perl version
use 5.008;

# explicitly include some modules for perl2exe
use SOAP::Transport::HTTP;
use Digest::Perl::MD5;
use XML::SAX;
use XML::SAX::Base;
use XML::SAX::Expat;
use XML::NamespaceSupport;
use LWP::UserAgent;
use SOAP::Lite;
use Encode qw( perlio_ok encode_utf8 decode_utf8 encode is_utf8 );
use PerlIO;

use File::Path;
use Digest::MD5 qw(md5_hex);
use Getopt::Std;
use XML::Simple;
use XMLRPC::Lite
#	+trace      => qw( transport debug ),
	on_fault	=> sub {
		my ($soap, $res) = @_;
		if (ref $res) {
			warn "\n--- LIVEJOURNAL FAULT ---\n", 
				$res->faultcode, ": ",
				$res->faultstring, "\n";
				die "Aborting...\n\n";
		} else {
			warn "\n--- HTTP ERROR ---\n", 
			$soap->transport->status, "\n";
		}
		return new SOAP::SOM;
	}
;


#use Devel::Peek;
use Data::Dumper;
use Carp;
#use diagnostics;
#use warnings;
#use strict;

use constant URL		=> 'http://www.livejournal.com/interface/xmlrpc';
use constant LOCALDIR	=> '';
use constant CLIENT		=> 'Perl-ljpms/1.4; sasha_nikolaev@yahoo.com';
use constant MAXTRY		=> 5;
use constant VERSION	=> '$Revision: 1.4 $';




# ***************************************************************************************
# **********************************  main  *********************************************
# ***************************************************************************************


XML::SAX->add_parser(q(XML::SAX::Expat));

# valid 'modes' aka actions
my %modes = (
	'private'	=> \&do_private,
	'friends'	=> \&do_friends,
	'public'	=> \&do_public,
	'restore'	=> \&do_restore,
	'delete'	=> \&do_delete,
	'backup'	=> \&do_backup,
);

$|=1;
my ($user, $password, $mode, %opts, $entry);
my ($security, $allowmask, @server);

getopts('p:s:t:', \%opts);
exit(usage()) unless @ARGV == 2; # username:password and action required

# set proxy URL for LWP requests
if ($opts{'p'})
{
	$opts{'p'} = 'http://'.$opts{'p'} unless ($opts{'p'} =~ m{^http://});
	@server = (URL, 'proxy' => ['http' => $opts{'p'}]);
}
else
{
	@server = (URL);
}


# login as user
($user, $password) = split(':', $ARGV[0], 2);
$password = md5_hex($password);

# define source and target journals
my $tuser = (defined($opts{'t'}) && length($opts{'t'}))? $opts{'t'} : $user;
my $suser = (defined($opts{'s'}) && length($opts{'s'}))? $opts{'s'} : $user;

# sanity checks
exit(usage('nopassword')) unless $password;
$mode = lc($ARGV[1]);
exit(usage('invalidmode')) unless defined $modes{$mode};
exit (usage('noexport')) unless  ($mode eq 'backup') || (-d LOCALDIR . "$suser/export");


# login to server to check login-password information
# $responce is XML::RPC::struct
print "Logging in to server as $user... ";
if (my $res = &rpc('login', { 'clientversion'	=> CLIENT }))
{
	print " done.\n";
	print "Hello, " . $res->{'fullname'} . "\n";
	print $res->{'message'} if defined $res->{'message'};
	print "\nYou have read and/or write access to the following journals:\n";
	print join("\n", $user, @{$res->{'usejournals'}});
	print "\n";
	
}
else { exit 1; }

$modes{$mode}($suser, $tuser);
exit(0);




# ***************************************************************************************
# *****************************  subroutines  *******************************************
# ***************************************************************************************


sub do_private($$)
{
	my ($suser, $tuser) = @_;
	exit(usage('cant_modify_comunity')) if ($user ne $suser);
	print "Making private all entries of '$suser'\n";
	sleep 2;
	my $prepare = sub {
		my ($soap_message) = @_;
		$soap_message->{'usejournal'} = $suser;
		$soap_message->{'security'} = 'private';
		return $soap_message;
	};
	&process_files('editevent', $prepare, $suser);
}



sub do_friends($$)
{
	my ($suser, $tuser) = @_;
	exit(usage('cant_modify_comunity')) if ($user ne $suser);
	print "Making all entries of '$suser' friends-only\n";
	sleep 2;
	my $prepare = sub {
		my ($soap_message) = @_;
		$soap_message->{'usejournal'} = $suser;
		$soap_message->{'security'} = 'usemask';
		$soap_message->{'allowmask'} = 1;
		return $soap_message;
	};
	&process_files('editevent', $prepare, $suser);
}



sub do_public($$)
{
	my ($suser, $tuser) = @_;
	exit(usage('cant_modify_comunity')) if ($user ne $suser);
	print "Making all entries of '$suser' public\n";
	sleep 2;
	my $prepare = sub {
		my ($soap_message) = @_;
		$soap_message->{'usejournal'} = $suser;
		$soap_message->{'security'} = 'public';
		return $soap_message;
	};
	&process_files('editevent', $prepare, $suser);
}



sub do_restore($$)
{
	my ($suser, $tuser) = @_;
	print "Posting ${suser}'s backdated entries to ${tuser}'s journal\n";
	print "Notice: changing security mode of all entries to 'public'\n" if ($tuser ne $user);
	sleep 2;
	my $prepare = sub {
		my ($soap_message) = @_;
		delete $soap_message->{'itemid'};
		if ($suser eq $user)
		{
			$soap_message->{'props'}->{'opt_backdated'} = 1;
		}
		$soap_message->{'security'} = 'public' if ($tuser ne $user);
		$soap_message->{'usejournal'} = $tuser;
		return $soap_message;
	};
	&process_files('postevent', $prepare, $suser);
}



sub do_delete($$)
{
	my ($suser, $tuser) = @_;

	my $prepare = sub {
		my ($soap_message) = @_;
		my %required_fields = (
				'itemid'	=> 1,
				'ver'		=> 1,
				'event'		=> 1,
				'subject'	=> 1,
				'security'	=> 1,
				'usejournal'    => 1,
		);

		foreach my $key (keys %{$soap_message})
		{
			delete $soap_message->{$key} unless defined $required_fields{$key};
		}
		$soap_message->{'event'} = '';
		$soap_message->{'subject'} = '';
		$soap_message->{'security'} = 'public';
		$soap_message->{'usejournal'} = $suser;
		return $soap_message;
	};

	warn <<EOM;
--------------------  WARNING!!! --------------------------
      The journal of $suser will be erased now.
      You will NOT be able to restore it. Never.
Press Ctrl-C in 10 seconds if you don't want this to happen
-----------------------------------------------------------

EOM
	for (1..10) {
		print "$_ ";
		sleep 1;
	}
	print "\nok. deleting all $suser\'s journal entries...\n";
	&process_files('editevent', $prepare, $suser);
}



sub do_backup($$)
{
	my ($suser, $tuser) = @_;
	print "Updating backup of '$suser' journal\n";
	exit &usage('cantsync') unless &sync_events($suser);
}



sub process_files($$)
{
	my($method, $preprocess, $usejournal) = @_;
	my $soap_message;

	FILES:
	foreach my $file (grep(/^\d{4}_\d{2}\.xml$/, &read_dir(LOCALDIR . "$usejournal/export"))) {
		print "processing $usejournal/export/$file\n";

		foreach my $entry (&get_entries(LOCALDIR . "$usejournal/export/$file")) {
			print $entry->{'itemid'} . "\n";
			$soap_message = &$preprocess( &make_message($entry) );
			last FILES unless &rpc($method, $soap_message);
		}
	}
}


sub get_entries {
	my ($filename) = @_;
	
	my $xi = XMLin( &get_file($filename) );
	my @data = ();
	if (! defined $xi->{'entry'}) {
		@data = ();
	} elsif (ref $xi->{'entry'} eq 'HASH') {
		@data = ($xi->{'entry'});
	} elsif (ref $xi->{'entry'} eq 'ARRAY') {
		@data = @{$xi->{'entry'}};
	}

	return sort {$a->{'logtime'} cmp $b->{'logtime'}} @data;
}


sub make_message {
	my ($entry) = @_;
	my ($year, $month, $day, $hour, $min) = split(/\D+/, ($entry->{'eventtime'} or $entry->{'logtime'}));
	my $soap_message = {
			'ver'			=> 1,
			'lineendings'	=> "\n",
			
			'event'		=> my_encode($entry->{'event'}),
			'subject'	=> my_encode($entry->{'subject'}),
			'security'	=> $security,
			'allowmask'	=> $allowmask,
			'itemid'    => $entry->{'itemid'} >> 8,
			
			'year'		=> $year,
			'mon'		=> $month,
			'day'		=> $day,
			'hour'		=> $hour,
			'min'		=> $min,
	};

	foreach ('current_music', 'current_mood', 'current_location', 'picture_keyword', 'opt_noemail', 'opt_screening', 'opt_preformatted', 'opt_nocomments', 'taglist') {
		if (defined($entry->{$_})) {
			$soap_message->{'props'}->{$_} = &my_encode($entry->{$_});
		} 
	}
	return $soap_message;
}


sub sync_events {
    my ($user) = @_;

	print "Invalid user name: '$user'\n" && return undef unless $user =~ /^\w+$/;
	my $dirname = LOCALDIR . "$user/export";
	my $syncfile = $dirname . "/last-sync-time.txt";

	mkpath($dirname) unless -d $dirname;
	# read recent data

	my $lastsync = &get_file($syncfile);
	$lastsync = '2001-01-01 00:00:00' unless $lastsync;
    print "syncing meta items since $lastsync\n";
	
	my ($res, $newevents);
	$newevents = 0;
	do {
		print "syncing data...";
		$res = &rpc('syncitems', {
			'usejournal'    => $user,
			'lastsync'	    => $lastsync,
			});

		if ($res) {
			print $res->{'count'} . " new item" . (($res->{'count'} == 1)? ".\n" : "s.\n");
			print (($res->{'count'})? "fetching new/modified posts...\n" : "\n");

			my ($res2, $item);

			foreach $item (@{$res->{'syncitems'}}) {
				$lastsync = $item->{'time'} if ($item->{'time'} gt $lastsync);
				# skip comments, todos, etc
				next unless $item->{'item'} =~ /^L-(\d+)$/;
				$newevents++;
				$res2 = &rpc('getevents', {
						'usejournal'    => $user,
						'selecttype'	=> 'one',
						'itemid'		=> $1,
						'ver'			=> 1,
						});
				if ($res2) {
					print $item->{'item'} . " ok\n";
					&save_item($res2->{'events'}->[0]);
				} else {
					last;
				}
			}
		}
	} until (!$res || ($res->{'total'} == $res->{'count'}));
	return 1 unless $newevents;

	print "$newevents new entries. rebuilding XML backup... ";
	&put_file($syncfile, \$lastsync);

	# join xml files to imitate export.bml behaviour
	my $localbase = LOCALDIR . "$suser/export";
	my @years = grep { /^\d{4}$/ && -d "$localbase/$_" } &read_dir($localbase);
	foreach my $year (@years) {
		my @months = grep { /^\d{2}/ && -d "$localbase/$year/$_" } &read_dir("$localbase/$year");
		foreach my $month (@months) {
			my $thisdir = "$localbase/$year/$month";
			my @files = grep { /^\d+\.xml$/ && -s "$thisdir/$_" } &read_dir($thisdir);
			my $month_contents = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
			$month_contents .= "<livejournal>\n";
			foreach my $xmlfile (sort @files) {
				$month_contents .= &get_file("$thisdir/$xmlfile") . "\n";
			}
			$month_contents .= "</livejournal>";
			&put_file("$localbase/$year\_$month.xml", \$month_contents);

		}
	}
	print "done. \n";
	1;
}

# write XML file with LJ post using export.bml-compatible scheme
#
sub save_item {
	my ($item) = @_;
	#print Dumper $item;
	my ($year, $month, $day, $tail) = split(/[-\s]/, $item->{'eventtime'});
	mkpath(LOCALDIR . "$suser/export/$year/$month");

	my $itemid = $item->{'itemid'}*256 + $item->{'anum'};
	my $fname = LOCALDIR . "$suser/export/$year/$month/$itemid.xml";
	my $props = $item->{'props'};

	my (@rt, $revtime);
	if (defined $props->{'revtime'}) {
		@rt = localtime($props->{'revtime'});
		$revtime = sprintf('%4d-%02d-%02d %02d:%02d:%02d', $rt[5]+1900, $rt[4]+1, $rt[3], $rt[2], $rt[1], $rt[0]);
	}

	# need to specify 8859-1 encoding because utf gets screwed otherwise
	# this makes things incompatible with 5.6. Anybody cares?
	open my $fh, '>:encoding(utf8)', $fname or die "open $fname: $!";
	#binmode $fh, ':utf8';

	my $entry = {
		'entry' => {
			'itemid'	=> $itemid,
			'eventtime'	=> $revtime,
			'logtime'	=> $item->{'eventtime'},
			'security'	=> (defined $item->{'security'})? $item->{'security'} : 'public',
			'allowmask'	=> (defined $item->{'allowmask'})? $item->{'allowmask'} : 0,
			'subject'	=> decode_utf8($item->{'subject'}, Encode::FB_XMLCREF),
			'event'		=> decode_utf8($item->{'event'}, Encode::FB_XMLCREF),
			'taglist'			=> decode_utf8($props->{'taglist'}),
			'picture_keyword'	=> decode_utf8($props->{'picture_keyword'}),
			'current_music'		=> decode_utf8($props->{'current_music'}),
			'current_mood'		=> decode_utf8($props->{'current_mood'}),
			'current_location'	=> decode_utf8($props->{'current_location'}),
			'opt_noemail'		=> $props->{'opt_noemail'},
			'opt_screening'		=> $props->{'opt_screening'},
			'opt_preformatted'	=> $props->{'opt_preformatted'},
			'opt_nocomments'	=> $props->{'opt_nocomments'},
		}
		};

	#print Devel::Peek::Dump $entry->{'entry'}->{'event'};

	XMLout(
		$entry,
		'KeepRoot'		=> 1,
		'NoAttr'		=> 1,
		'SuppressEmpty'	=> 1,
		'OutputFile'	=> $fh,
	);
	close $fh;
	1;
}


sub rpc {
	my ($query_name, $query_data) = @_;

	my $res;
	$query_data->{'username'} = $user;
	$query_data->{'hpassword'} = $password;

	#print Dumper $query_data;

	for (1 .. MAXTRY) {
		$res = XMLRPC::Lite
		->proxy(@server)
		->call('LJ.XMLRPC.' . $query_name, $query_data )
		->result();

		if ($res) {
			#print " ok\n";
			last;

		} elsif ($_ == MAXTRY) {
			print " FAILED!\n";
		}
		sleep 2;
	}
	return $res;
}


sub read_dir {
	my ($dir) = @_;

	my @inside = ();
	return @inside unless -d $dir;
	opendir(DIR, $dir) || croak("can't open $dir directory: $!");
	@inside = readdir(DIR);
	closedir DIR;
	return @inside;
}


sub get_file {
	my ($fname) = @_;
	my ($buffer, $contents);
	return undef unless -f $fname;
	return '' unless -s $fname;
	open DF, '<:encoding(utf8)', $fname or croak("error opening '$fname' for reading: $!");
	#binmode DF, ':utf8';
	while (read(DF, $buffer, 4096)) {
		croak("error reading '$fname': $!") unless defined $buffer;
		$contents .= $buffer;
	}
	close DF or croak("error closing '$fname': $!");
	return $contents;
}


sub put_file {
	my ($fname, $contents) = @_;
	open DF, '>:encoding(utf8)', $fname or croak( "error opening '$fname' for writing: $!" );
	#binmode DF, ':utf8';
	print(DF $$contents) or croak( "error writing contents to '$fname': $!" );
	close DF or croak( "error closing '$fname': $!" );
}


sub my_encode {
	my ($str) = @_;
	return '' if (ref $str);
	#return $str;
	return is_utf8($str)? encode_utf8($str) : $str;
}


sub usage {
	my ($error) = @_;
	$user = 'USER' unless defined $user;
	$suser = 'USER' unless defined $suser;
	my %errmsg = (
		'cant_modify_comunity'  => "can't modify permissions of comunity entries",
		'nopassword' 	=> 'use username:password as a first argument',
		'invalidmode'	=> 'mode is one of: private,friends,public,restore,delete',
		'noexport'		=> LOCALDIR . "$suser/export directory should contain xml files exported by ljsm\n#ERROR: (use ljsm -X -u $suser\:password)",
		'cantsync'		=> "Can't update backup data for $suser. Aborting...",
	);
	if ($error) {
		warn "#ERROR: $errmsg{$error}\n";
		
	} else {
		warn "ljpms - utility for batch modification of LiveJournal posts security level\n";
		warn "usage: $0 [-p proxy] [-s source_user] username:password mode\n";
		warn "-s source_user: post source_user's backdated entries to username's journal\n";
		warn "-t target_user: post source_user's backdated entries to target_user's journal\n";
		warn "mode: backup|private|friends|public|restore|delete\n";
		warn VERSION . "\n";
	}
	1;
}
