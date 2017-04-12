#!/usr/bin/env perl
# CVS: $Id: ljsm.pl,v 2.12 2017/04/10 09:18:00 sasha Exp $
# Author: Alexander Nikolaev <variomap@gmail.com>
#perl2exe_info FileDescription=Utility for Livejournal.com backup
#perl2exe_info ProductName=LJSM
#perl2exe_info ProductVersion=2.12.0.0
#perl2exe_info FileVersion=2.12.0.0
#perl2exe_info LegalCopyright=GPL
#perl2exe_info CompanyName=Alexander Nikolaev


=head1 SYNOPSYS

see usage() subroutine for usage summary

=head1 SETUP

 I've tested this script with Windows Me/XP, ActiveState perl v. 5.6.0-5.8.0

 with the following ppm modules installed:
 libwww-perl 5.48


=head1 TODO

 - [?] fix -d and -O interaction
 - [x] add charset pragma to index.html
 - [x] add command-line switch for image download
 - [x] add &usescheme=lynx to lj queries.
 - [x] proxy support
 - [-] usable pager
 - [x] better date range handling (command-line switch?),
 - [x] explicitly show
 	"You must be logged in to view this protected entry" and
	"This journal is deleted." cases in the index file
 - [x] no comments download
 - [ ] remove javascript from downloaded files
 - [ ] generate windows help project (.hhp) file for downloaded journals

=head1 LINKS

http://www.offtopia.net/ljsm/
http://www.livejournal.com/talkread.bml?journal=ru_hitech&itemid=118529
http://www.livejournal.com/talkread.bml?itemid=122758&journal=ru_hitech
http://www.livejournal.com/talkread.bml?journal=ru_hitech&itemid=158872
http://www.livejournal.com/talkread.bml?itemid=394253&journal=rulj
http://www.livejournal.com/community/rulj/532637.html
http://www.livejournal.com/community/rulj/595146.html
http://www.livejournal.com/community/rulj/854727.html
http://www.livejournal.com/community/lj_clients/133229.html
http://www.livejournal.com/community/lj_clients/197260.html

=head1 SUBROUTINES

=cut

use constant {
	LOGIN			=> '',	# leave it empty if you don't want to login
	PASSWORD		=> '',
	START_YEAR		=> 2001,	# fetch data back to this year
	UTF8_DECODE		=> 0,		# convert text to local charset
	LOCAL_CHARSET	=> 'windows-1251', # windows cyrillic
	DEBUG_LEVEL		=> 3,		# 0 - quiet, 1 - essential, 2 - verbose
	LOCAL_DIR		=> '',		# local directory to put files into. Leave it empty to put in the current directory. Slash (/, if not empty) in the end required.
	HTTP_PROXY		=> '',		# set proxy URL if you use http proxy
	CLIENT			=> 'Perl-ljsm/2.12; variomap@gmail.com',
	CVSVERSION		=> '$Revision: 2.12 $', # don't touch this
	SAVE_PICS		=> 1,	# download standard icons (1) usepics (2) or all graphics referenced by post (3)
	BASE_DOMAIN		=> 'livejournal.com' #'lj.rossia.org'
};

# ===================================================================
# end of public constants definition. no user-editable parts below this line
# ===================================================================
use constant BASE_URL	=> 'http://www.' . BASE_DOMAIN . '/';

use constant {
	MAX_TRIES		=> 5, # max tries to get page in case of failure
	CATALOG_URL		=> BASE_URL . 'view/?type=month',
	LOGIN_SCRIPT	=> 'login.bml',
	POST_SCRIPT		=> 'talkread.bml',
	POST_SCRIPTNOC	=> 'talkpost.bml',
	MEMO_SCRIPT		=> 'tools/memories.bml',
	EXPORT_SCRIPT	=> 'export.bml',
	INTERFACE		=> BASE_URL . 'interface/flat',
	THREADER		=> 'http://lj.setia.ru/threader/threader.php', # external service to expand collapsed threads
	BROKEN_CLIENT_INTERFACE	=> 1 # sessiongenerate call does not return nessesary cookies
};

#use Data::Dumper;
#use LWP::Debug qw(+debug +conns);
#use Carp;

use LWP::UserAgent;
use HTTP::Cookies;
use File::Path;
use File::Basename;
use File::Find;

use Compress::Zlib;
use Digest::MD5 qw(md5_hex);
use Getopt::Std;
use strict;

my ($ua, $req, $res, $login, @posts, %images, $user, %users, %stat, %memories, %posts, $umask);
our ($opt_r, $opt_m, $opt_a, $opt_c, $opt_O, $opt_i, $opt_I, $opt_u, $opt_U, $opt_x, $opt_t, $opt_p, $opt_d);

# open log file (delete it if there were no errors)
$umask = umask 0077;
open LF, ">>ljsm.log" or die "error opening ljsm.log for appending: $!\n";
umask $umask;
print LF "\n============= " . join(' ', @ARGV) . "\n";
print LF scalar localtime() . "\n";

# steal options from @ARGV before we go for users
getopts('rmacxtOIUu:p:d:i:');
$opt_i = SAVE_PICS if (!$opt_i);

usage() && exit unless (@ARGV);


# rebuild indexes and exit if -x option is set
if ($opt_x) {
	foreach $user (@ARGV) { # for each user
		%users = ();
		logmsg("rebuilding index file for user $user...\n");
		build_index($user);
		logmsg(" done.\n");
	}
	exit 0;
}

# init global vars
$stat{$_} = 0 foreach ('users','pages_ok','got_posts','images');
%images = ();

$ua = new LWP::UserAgent;
$ua->agent(CLIENT);
$ua->cookie_jar(new HTTP::Cookies(
#	file		=> "ljcookies.txt",
	autosave	=> 0)
);
push @{ $ua->requests_redirectable }, 'POST';

# set proxy URL for LWP requests
$ua->proxy('http', HTTP_PROXY) if HTTP_PROXY;
if ($opt_p) {
	$opt_p = "http://$opt_p" unless ($opt_p =~ m{http://});
	$ua->proxy('http', $opt_p);
}

# threader uses POST redirect
$ua->requests_redirectable(['GET', 'POST']) if $opt_t;

# get cookies
exit 1 unless (!(LOGIN || $opt_u) || ($login = lj_login()));

# get posts and memories
foreach $user (@ARGV) { # for each user
	%memories = %posts = %users = ();
	@posts = ();
	$stat{'count_posts'} = $stat{'count_memos'} = 0;
	logmsg("\n\n=== processing user $user\n");

	push @posts, get_memos($user) if ($opt_m || $opt_a);
	push @posts, get_posts($user) unless ($opt_m && !$opt_a);
	get_files($user);
	build_index($user) if @posts;
	undef @posts; # free memory
	$stat{'users'}++;
}

# get images
if (($stat{'got_posts'} > 0) &&
	(scalar keys %images) &&
	$opt_i) {
	get_pics();
}



#   ============================================
#                  subroutines
#   ============================================

# http://www.livejournal.com/talkread.bml?journal=ru_hitech&itemid=118529
# http://users.livejournal.com/_a_/2001/05/ (calendar view)
# http://ati.livejournal.com/2001/05/ (calendar view 2)
# http://www.livejournal.com/tools/memories.bml?user=_a_ (memories)
# http://ivan-da-marya.livejournal.com/40324.html (post, user with underscores)
# http://users.livejournal.com/_a_/570.html (post, user with uderscores -2 )
# http://community.livejournal.com/lj_dev/1234.html (post in comunity)
# http://community.livejournal.com/rulj/862105.html (post in community without underscores)
# http://users.livejournal.com/4x-/189231.html
# (same as http://rulj.livejournal.com/862105.html)
#
# link type may be
# P - post
# Q - post in community
# M - memories
# C - month view for calendar
#
sub parse_link {
	my ($link) = @_;
	my ($link_type, $user, $post_id);

	my %url_parts = (
		'/tools/memories.bml\?user=([-\w]+)'	=> 'M',
		'/users/([-\w]+)/(\d+).html'			=> 'P',
		'/~?([-\w]+)/(\d+).html'				=> 'P',
		'/\d+.html'							=> ['P', "^http://([-\\w]+)\\.@{[BASE_DOMAIN]}/(\\d+)"],
		'/community/([-\w]+)/(\d+).html'		=> 'Q',
		'/[-\w]+/\d+.html'						=> ['X', "^http://(?:users|community)\\.@{[BASE_DOMAIN]}/([-\\w]+)/(\\d+)"],
		'/users/([-\w]+)/\d{4}/\d{2}/'			=> 'C',
		'/([-\w]+)/\d{4}/\d{2}/'				=> 'C',
		'/~([-\w]+)/\d{4}/\d{2}/'				=> 'C',
		'/\d{4}/\d{2}/'						=> ['C', "^http://([-\\w]+)\\.@{[BASE_DOMAIN]}"],
		'/talkread.bml\?journal=([-\w]+)&itemid=(\d+)'	=> 'P'
	);

	$link_type = '';

	foreach my $part (keys %url_parts) {
		if ($link =~ m#@{[BASE_DOMAIN]}$part#) {
			if (ref($url_parts{$part})) { # match against second regexp
				$link_type = $url_parts{$part}->[0];
				$link =~ m#$url_parts{$part}->[1]#;
				if ($link_type eq 'X') { # user or community post?
					$link_type = ($link =~ m#http://community#)? 'Q' : 'P';
				}
				$user = $1;
				$post_id = $2;
			} else {
				$link_type = $url_parts{$part};
				$user = $1;
				$post_id = $2;
			}
			last;
		}
	}

	$user =~ s/-/_/g if (defined $user);
	return ($link_type, $user, $post_id);
}

sub make_link {
	my ($link_type, $user, $post_id) = @_;

	#warn "make_link: $link_type, $user, $post_id\n";
	return undef unless defined $user;
	(print("INTERNAL ERROR: don't know how to make links of type $link_type\n") && return undef)
		unless $link_type =~ /[PQ]/;


	my $prefix = 'http://';
	if ($user =~ /^_/) {
		$prefix .= ($link_type eq 'Q')? "community.@{[BASE_DOMAIN]}" : "users.@{[BASE_DOMAIN]}";
		$prefix .= "/$user";
	} else {
		$user =~ s/_/-/g;
		$prefix .= "$user.@{[BASE_DOMAIN]}";
	}
	$prefix .= "/$post_id.html";
	return $prefix;
}


=item get_date_range($user)

get year and month of the last downloaded post

=cut
sub get_date_range {
	my ($user, $is_xml) = @_;

	my ($start_year, $start_month, $end_year, $end_month, @date, $t);

	@date = localtime();

	# get end date
	if ($opt_d) {
		($start_year, $start_month, $end_year, $end_month) = split(/\D/, $opt_d);

		$end_year = $date[5]+1900 unless $end_year;
		$end_month = $date[4]+1 unless $end_month;

		# swap dates if specified in reversed order
		if ($start_year > $end_year) {
			($start_year, $end_year, $start_month, $end_month) = ($end_year, $start_year, $end_month, $start_month);
		} elsif (($start_year == $end_year) && ($start_month > $end_month)) {
			($start_month, $end_month) = ($end_month, $start_month);
		}

		return ($start_year, $start_month, $end_year, $end_month);

	} else {
		$start_year = START_YEAR;
		$start_month = 1;
		$end_year  = $date[5] + 1900;
		$end_month = $date[4] + 1;
	}

	# set start_year, start_month based on the downloaded posts
	if (!(-d LOCAL_DIR . $user) || $opt_O || $opt_r) {
		return ($start_year, $start_month, $end_year, $end_month);
	}

	if (!$is_xml) { # date range between last post and current month
		opendir(UD, LOCAL_DIR . $user) or die "error opening " . LOCAL_DIR . "$user directory for reading: $!\n";
		my ($year) = sort {$b <=> $a } grep(/^\d+$/, readdir(UD));
		closedir UD;
		return ($start_year, $start_month, $end_year, $end_month) unless $year;

		opendir(UD, LOCAL_DIR . "$user/$year") or die "error opening " . LOCAL_DIR . "$user/$year directory for reading: $!\n";
		my ($month) = sort {$b <=> $a } grep(/^\d+$/, readdir(UD));
		closedir UD;
		$month = 1 unless $month;

		return ($year, $month, $end_year, $end_month);


	} else { # date range for XML export
		opendir(UD, LOCAL_DIR . $user . '/export') or die "error opening " . LOCAL_DIR . "$user/export directory for reading: $!\n";
		my ($lastfile) = reverse sort grep (/^\d+_\d+\.xml$/, readdir UD);
		closedir UD;
		if ($lastfile && ($lastfile =~ /^(\d+)_(\d+)/)) {
			$start_year = $1;
			$start_month = $2;
		}
		return ($start_year, $start_month, $end_year, $end_month);
	}
}




=item get_pics()

download userpics, buttons etc

=cut
sub get_pics {
	my ($imgsrc, $img);

	logmsg("getting pictures...\n",2);
	foreach $imgsrc (keys %images) {
		# test if there is already image with the same name
		next if (-f $images{$imgsrc});

		# get image
		if ($img = get_page($imgsrc, 1)) {
		 	mkpath(dirname($images{$imgsrc}), DEBUG_LEVEL, 0755)
				unless -d dirname($images{$imgsrc});
			if (open (DF, ">$images{$imgsrc}")) {
				binmode DF;
				print DF $img;
				close DF;
				$stat{'images'}++;
			} else {
				logmsg("error opening $images{$imgsrc} for writing: $!\n",0);
			}
		} else {
			logmsg("error getting $imgsrc\n",0);
		}
	}
}



=item get_memos($user)

get list of user's memories and store them is $posts{memos}

=cut
sub get_memos {
	my ($user) = @_;
	my($content, $amuser, $keyword);
	my (@memos, $link, $link_post);

	logmsg("getting list of memories...\n",2);
	# get list of keywords
	if ($content = get_page(BASE_URL . MEMO_SCRIPT . "?user=$user")) {
		foreach $link (&tiny_link_extor(\$content, 0)) {
			next unless $link =~ /@{[MEMO_SCRIPT]}\?user=\w+\&keyword=(.*?)\&filter=all$/;
			$keyword = $1;
			$keyword = " " unless length $keyword;
			# unescape keywords
			$keyword =~  s/\+/ /g;
			$keyword =~  s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
			$keyword = from_utf8($keyword) if (UTF8_DECODE || $opt_U);

			# get list of posts for the given keyword
			$link = BASE_URL . $link unless ($link =~ /^@{[BASE_URL]}/);
			if ($content = get_page($link)) {
				my ($link_type, $post_id);
				foreach $link_post (&tiny_link_extor(\$content, 0)) {
					($link_type, $amuser, $post_id) = &parse_link($link_post);
					next unless $link_type =~ /[PQ]/;
					next unless ($opt_O || ! -f LOCAL_DIR . "$user/memories/$amuser\_$post_id.html");
					push @memos, {
						'type'		=> 'memo',
						'link_type'	=> $link_type,
						'status'	=> 0,
						'amuser'	=> $amuser,
						'keyword'	=> $keyword,
						'link'		=> $link_post,
						'itemid'	=> $post_id
					};
				}

			} else { # error fetching list of posts
				logmsg("error fetching list of posts for user $user, keyword $keyword",0);
			}
		}
	} else { # error fetching list of keywords
		logmsg("error fetching list of keywords for $user\n",0);
	}

	return @memos;
}


=item get_posts($user)

get list of user's posts and store them in $posts{posts}

=cut
sub get_posts {
	my ($user) = @_;
	my ($content, $year, $month, @posts, $link, $emonth, $itemid, $link_type, $post_id, $amuser);

	@posts = ();
	my ($start_year, $start_month, $end_year, $end_month) = get_date_range($user);
	logmsg("getting posts links for $user " .
		sprintf("[ %4d/%02d - %4d/%02d ]", $start_year,$start_month,$end_year,$end_month) . "\n");

	$year = $end_year;
	YEAR:
	while ($year >= $start_year) {
		$emonth = ($year == $start_year)? $start_month : 1;
		for ($month = 12; $month >= $emonth; $month--) {
			next if (($year == $end_year) && ($month > $end_month));

			#fetch catalog data
			if ($content = get_page(CATALOG_URL . "&user=$user&y=$year&m=$month")) {
				# process links.
				foreach $link (reverse sort &tiny_link_extor(\$content, 0)) {
					($link_type, $amuser, $post_id) = &parse_link($link);
					next unless $link_type =~ /[PQ]/;
					push @posts, {
						'type'		=> 'post',
						'link_type'	=> $link_type,
						'status'	=> 0,
						'year'		=> $year,
						'month'		=> $month,
						'link'		=> $link,
						'itemid'	=> $post_id,
						'amuser'	=> $user,
						'keyword'	=> '',
						'comments'	=> ($content =~ m#$post_id\.html\D+(\d+)\s+repl#)? $1 : 0
					};
				} # link loop on the catalog page

			} else { # error fetching catalog data
				logmsg("!! Error fetching catalog data. Going on with " . @posts . " posts\n");
				return @posts unless $opt_I;
			}
		} # months loop
		$year--;
	} # years loop
	return @posts;
}

=item get_files($user)

download and process posts and memories.

=cut
sub get_files {
	my ($user) = @_;
	my ($post, $content, $dir, $fname, $result, $extor, $up, $navbar, $n, $myhref);


	my $charset = "<meta http-equiv=\"Content-Type\" content=\"text/html; ";
	$charset .= (UTF8_DECODE || $opt_U)?  "charset=@{[LOCAL_CHARSET]}\">" : "charset=utf-8\">";

	#print "going to get " . (scalar @posts) . " posts.\n";
	logmsg((@posts)? "getting posts...\n" : "No new posts to download.\n");
	foreach $post (@posts) {
		if ($post->{'type'} eq 'post') {
			$dir = LOCAL_DIR . "$user/$post->{year}/$post->{month}";
			$fname = "$post->{itemid}.html";
			$up = "../../..";

		} else { # memo
			$dir = LOCAL_DIR . "$user/memories";
			$fname = "$post->{amuser}_$post->{itemid}.html";
			$up = "../..";
		}

		if (-s "$dir/$fname") {
			if ($opt_O) {
				logmsg("!! overwriting $dir/$fname\n", 2);
			} elsif ($opt_r) {
				logmsg("-r: skipping $dir/$fname\n", 2);
				next;
			} else {
				last;
			}
		}

		# old scheme
		if ($post->{'link'} =~ m#(journal=\w+&itemid=\d+)#) {
			$myhref = POST_SCRIPT . "?$1";
			$post->{'link'} =~ s/@{[POST_SCRIPT]}/@{[POST_SCRIPTNOC]}/ if ($opt_c);
		}
		# new scheme
		if ($post->{'link'} =~ m#/(\d+)\.html#) {
			$myhref = "$1.html";
			$post->{'link'} .= '?mode=reply' if ($opt_c);
		}

		my $need_threader =
			defined($post->{'comments'}) &&
			($post->{'comments'} >= 50) &&
			$opt_t && !$opt_c;

		if ($content = get_page($post->{'link'}, 0, $need_threader)) {
			$stat{'got_posts'}++;
			mkpath($dir, DEBUG_LEVEL, 0755);
			&cleanup_html(\$content, $myhref, $user);
			&rewrite_imgsrc(\$content, $up, $user) if ($opt_i);
			$content = from_utf8($content) if (UTF8_DECODE || $opt_U);

			$content =~ s/<!-- keywords -->/<link rel="stylesheet" href="$up\/post.css" type="text\/css">\n<meta name="keywords" content="$post->{'keyword'}">\n$charset/;

			logmsg(">> $dir/$fname\n",2);
			open DF,">$dir/$fname" or die "error opening $dir/$fname for writing: $!\n";
			print DF $content;
			close DF;

			$post->{'status'} = 1;

		} else { # error fetching page
			print "error fetching " . $post->{'link'} . "\n";
			last unless $opt_I;
		}
	}
}


=item rewrite_imgsrc(\$page, $up)

rewrite img's src attribute depending on $opt_i

=cut
sub rewrite_imgsrc {
	my ($page, $up, $user) = @_;
	my ($src, $d1, $d2);

	logmsg("extracting img src's...\n", 4);
	# list of unique image src's
	%images = (%images, map {$_ => 1} &tiny_link_extor($page, 1));
	($d1, $d2) = split('\.', BASE_URL, 2);

	foreach $src (keys %images) {
		if ($src =~ m#stat\.${d2}img/(.*)$#) {
			if ($opt_i > 0) {
				$d1 = $1;
				$$page =~ s#src=["']\Q$src\E['"]#src='$up/img/$d1'#sg;
				$images{$src} = "img/$d1";
			} else {
				delete $images{$src};
			}

		} elsif ($src =~ m#userpic\.$d2(\d+/\d+)$#) {
			if ($opt_i > 1) {
				$d1 = $1;
				$$page =~ s#src=['"]\Q$src\E['"]#src='$up/userpic/$d1'#sg;
				$images{$src} = "userpic/$d1";
			} else {
				delete $images{$src};
			}

		} elsif ($opt_i > 2) {
			$d1 = $src;
			$d1 =~ s#^http://##;
			$d1 =~ s#[^(\w|\/|\.)]#_#g;
			$$page =~ s#src\s*=\s*['"]\Q$src\E['"]#src='$up/$user/img/$d1'#sg;
			$images{$src} = "$user/img/$d1";

		} else {
			delete $images{$src};
		}
	}
}



sub cleanup_html {
	my ($page, $myhref, $user) = @_;
	my ($result, $in_navbar, $in_reply, %links, $rlink);

	$in_navbar = 1;
	$in_reply = 0;
	$result = '';
	foreach (split(/\n/, $$page)) {
		$in_reply = 0 if (m#</BODY>#i);
		next if $in_reply;
		$in_reply = 1 if ($opt_c && m#<a href=["']\Q$myhref\E['"]>Read comments</a>#);
		s#<H1>.*##i if $in_reply;
		next if /^<p>\[ <a href=.*<\/a>\]<\/p>$/;

		# add css link and keywords hook
		s#</HEAD>#<!-- keywords -->\n</HEAD>#i;

		# remove action buttons and forms
		# (delete, screen, mass action etc)
		s#</?form.*?>##g;
		s#<input .*?\#?>##g;
		s#<a href=['"]talkscreen.bml.*?</a>##g;
		s#<a href=['"]delcomment.bml.*?</a>##g;
		s#<label.*?</label>##g;
		s#<nobr>\s*</nobr>##g;
		s#<p><b>Mass action.*$##g;
		s#<link href=.*?>##g;
		$result .= "$_\n";
	}

  # safety net for runaway regexps
  if (length($result) == 0) {
    logmsg("** Failed to parse '" . $myhref . "', saving original HTML page\n");
    $result = $$page;
  }

	# replace relative hrefs with absolute
	%links = map {$_ => 1} &tiny_link_extor(\$result, 0);
	my $prefix = 'http://';
	if ($user =~ /^_/) {
		$prefix .= "users.@{[BASE_DOMAIN]}/$user";
	} else {
		$user =~ s/_/-/g;
		$prefix .= "$user.@{[BASE_DOMAIN]}";
	}
	foreach $rlink (keys %links) {
		next if ($rlink =~ m#^https?://#);
		$rlink =~ s#^/##;
		$result =~ s#href=(['"])\Q$rlink\E\1#href="$prefix/$rlink"#sg
	}
	$$page = $result;
	1;
}


=item lj_login()

login to server, get cookies

=cut
sub lj_login {
	logmsg("logging in to " . BASE_URL . "... \n", 1);
	my ($user, $password) = ((defined $opt_u) && (length $opt_u > 0))?
		split(":", $opt_u, 2) : (LOGIN, PASSWORD);

	my ($status1, $lj1) = &lj_interface_query(
		{ 'mode'	=> 'getchallenge' }
	);

	if (!$status1) {
		my ($status2, $lj2) = &lj_interface_query(
			{
				'mode'			=> 'sessiongenerate',
				'user'			=> $user,
				'auth_method'	=> 'challenge',
				'auth_challenge' => $lj1->{'challenge'},
				'auth_response'	=> md5_hex($lj1->{'challenge'} . md5_hex($password)),
				'expiration'	=> 'long',
				'ipfixed'		=> 1
			}
		);

		if (!$status2) {
			my $isok = 0;
			if (BROKEN_CLIENT_INTERFACE) {
				# go get cookies to /login.bml
				my ($status1, $lj1) = &lj_interface_query(
					{ 'mode'	=> 'getchallenge' }
				);
				if (!$status1) {
					my $req = new HTTP::Request(POST => BASE_URL . LOGIN_SCRIPT);
					$req->content_type('application/x-www-form-urlencoded');
					my $content =
						"chal=".$lj1->{'challenge'} .
						"&response=".md5_hex($lj1->{'challenge'} . md5_hex($password)) .
						"&user=$user" .
						"&password=" .
						"&action:login=Log in...";
					$req->content($content);
					$res = $ua->request($req);
					$isok = $res->is_success;
					# carp Dumper $res;
				}
			} else {
				$ua->cookie_jar->set_cookie(undef, 'ljsession', $lj2->{'ljsession'}, '/', BASE_DOMAIN);
				$isok = 1;
			}

			if ($isok) {
				$ua->cookie_jar->set_cookie(undef, 'langpref', 'en_LJ/' . $lj1->{'server_time'}, '/', '.'.BASE_DOMAIN);
				$ua->cookie_jar->set_cookie(undef, 'BMLschemepref', 'lynx', '/', '.'.BASE_DOMAIN);
				$ua->cookie_jar->set_cookie(undef, 'CP', 'null*', '/', '.'.BASE_DOMAIN);
				logmsg("got LJ cookies.\n", 1);
				return 1;
			} else {
				logmsg('Error logging in to server.', 0);
				return undef;
			}

		} else {
			logmsg('Error logging in to server.', 0);
			return undef;
		}
	} else {
		logmsg('Error logging in to server.', 0);
		return undef;
	}
}




=item get_page($url)

download page from the remote host

=cut
sub get_page {
	my ($url, $is_image, $use_threader) = @_;

	if (!$is_image) {
		$url .= ($url =~ /\?/)? '&format=light' : '?format=light'
			if ($url !~ /format=light/);
    $url .= '&style=mine';
	}
	my $logprefix = ($use_threader)? "THREADER: " : '';
	logmsg("<< $logprefix$url\n",2);

	if ($use_threader){
		$req = new HTTP::Request(POST => THREADER);
		$req->content_type('application/x-www-form-urlencoded');

		my ($user, $password) = ((defined $opt_u) && (length $opt_u > 0))?
			split(':', $opt_u) : ();
		my $content = "addr=$url";
		$content .= "user=$user&password=$password" if $user;
		$req->content($content);

	} else {
		$req = new HTTP::Request GET => $url;
	}
	$req->header('Accept-Encoding' => 'gzip;q=1.0, *;q=0');

	foreach (1 .. MAX_TRIES) {
		logmsg("retrying $logprefix$url...\n", 0) if ($_ > 1);
		#send request
		$res = $ua->request($req);
		#process responce
		if ($res->is_success) {
			$stat{'pages_ok'}++;

			return ($res->content_encoding && ($res->content_encoding =~ /gzip/))?
				Compress::Zlib::memGunzip($res->content) : $res->content;

		} else {
			my $err = $res->error_as_HTML;
			$err =~ s/^[^\d].*$//mg;
			$err =~ s/[\n\r]+//g;
			logmsg("\n$err\n$_. retrying in 3 seconds...\n", 0);
			sleep 3;
		}
	}
	$stat{'pages_err'}++;
	logmsg("failed to get $url after @{[MAX_TRIES]} attempts\n",0);
	# save failed downloads to log file
	print LF "Failed: $url\n";
	return undef;
}


sub logmsg {
	my ($message, $loglvl) = @_;
	if (!defined $loglvl) {
		print $message;
	} else {
		#carp $message if ($loglvl <= DEBUG_LEVEL);
		print $message if ($loglvl <= DEBUG_LEVEL);
	}
}


=item build_index($user)

build index file for the given user

=cut
sub build_index {
	my ($user) = @_;
	my ($month, $year, @months);

	@months = ('','January','February','March','April','May','June',
	'July','August','September','October','November','December');

	# skip to next dir if there is no such user
	unless (-d LOCAL_DIR . $user) {
		logmsg(LOCAL_DIR . $user . " not found.");
		return;
	}

	# traverse directory tree calling process_html for each file found
	find({
			wanted => \&process_html_file,
			preprocess	=> \&sort_directory
		}, LOCAL_DIR . $user);

	# write index.html
	open DF, ">" . LOCAL_DIR . $user . "/index.html"
		or die "error opening " . LOCAL_DIR . $user . "/index.html" .
				"for writing: $!\n";

	my $charset = (UTF8_DECODE || $opt_U)? LOCAL_CHARSET : 'utf-8';
	print DF <<EOH;
<html>
	<head>
		<title>Index file for $user livejournal</title>
		<meta http-equiv="Content-Type" content="text/html; charset=$charset">
		<link rel="stylesheet" href="index.css" type="text/css">
	</head>
	<body>
	<a name="top"></a>
	<hr width="550" size="3" noshade align="left">
	<font size="+2"><b><a href="@{[BASE_URL]}users/$user">$user</a></b>'s livejournal.&nbsp;&nbsp;</font>
EOH
	print DF "<font size=\"+1\">$stat{count_memos} <a href=\"#memories\">memories</a></font> "
		if (scalar keys %memories);

	if (scalar keys %posts) {
		print DF "<font size=\"+1\"> | $stat{count_posts} posts: ";
		foreach (sort keys %posts) { # foreach year
			print DF "<a href=\"#$_\">$_</a> ";
		}
		print DF "</font>\n";
	}

	print DF "<br><tt><b>last updated:</b> " . (scalar localtime) . "</tt>\n";
	print DF '<hr width="550" size="3" noshade align="left">' . "\n";


	my ($postid, $title, $locallink, $key, $amuser, $itemid, $link, $metapost, $filename);

	if (scalar keys %posts) {
		foreach $year (reverse sort keys %posts) { # $posts{$year} is a reference to the hash of months
			# year header
			print DF "<a name=\"$year\"></a>\n";
			print DF '<p><hr width="550" size="1" noshade align="left">' . "\n";
			print DF '<b><font size="+1"><a href="#top">' . $year . '</a>: </font></b><font size="-1">';
			print DF "<a href=\"#$year-$_\">" .
				$months[$_+0] . "</a> | "
				foreach (sort {$a <=> $b} keys %{$posts{$year}});
			print DF '</font><hr width="550" size="1" noshade align="left"><br>' . "\n";

			# year body
			for  $month (reverse sort {$a <=> $b} keys %{$posts{$year}}) {
				print DF "<a name=\"$year-$month\"></a>[ <b>$months[$month]</b> ]<br>\n";
				for  $metapost (@{$posts{$year}->{$month}}) {
					# make separate link if there is a link in a title (avoid nested <a>'s)
					$postid = $metapost->{'itemid'};
					$filename = $metapost->{'filename'};
					$title = $metapost->{'title'};
					$title = '<i>no title</i>' unless ($title =~ /\S/);
					$locallink = (index($title, '<a') > -1)?
						"[<a href=\"$year/$month/$filename\" target=\"post\">read</a>]&nbsp; $title" :
						"<a href=\"$year/$month/$filename\" target=\"post\">$title</a>";

					print DF "<font color=\"gray\" size=\"-1\">" . $metapost->{'day'} . "</font> $locallink &nbsp;&nbsp;| <a href=\"" . &make_link($metapost->{'link_type'}, $metapost->{'amuser'}, $metapost->{'itemid'}) . "?usescheme=lynx\" target=\"_new\"><b>&raquo;</b></a><br>\n";
					print DF "<p>\n";
				}
			}
		}
	}
	if (scalar keys %memories) {
		print DF '<a name="memories"></a>'. "\n";
		print DF '<hr width="550" size="1" noshade align="left">' . "\n";
		print DF '<b><font size="+1"><a href="#top">Memories</a>: </font></b>' . "\n";
		print DF '<hr width="550" size="1" noshade align="left">' . "\n";
#
		# foreach keyword
		foreach $key (sort keys %memories) {
			print DF "<dl>\n<dt><b>$key</b></dt>\n";
			foreach $metapost (@{$memories{$key}}) {
				$amuser = $metapost->{'amuser'};
				$itemid = $metapost->{'itemid'};
				$title = $metapost->{'title'};
				$filename = $metapost->{'filename'};
				$title = '<i>no title</i>' unless ($title =~ /\S/);

				$link = ($amuser)? &make_link($metapost->{'link_type'}, $amuser, $itemid) ."?usescheme=lynx" :
					"@{[POST_SCRIPT]}?itemid=$itemid&usescheme=lynx";

				# make separate link if there is a link it title (avoid nested <a>'s)
				$locallink = (index($title, '<a') > -1)?
					"[<a href=\"memories/$filename\" target=\"post\">read</a>]&nbsp; $title" :
					"<a href=\"memories/$filename\" target=\"post\">$title</a>";

				print DF "<dd><b><a href=\"@{[BASE_URL]}userinfo.bml?user=$amuser&mode=full&usescheme=lynx\">*</a>&nbsp;<a href=\"@{[BASE_URL]}users/$amuser/\">$amuser</a></b>: &nbsp; $locallink &nbsp;&nbsp;| <a href=\"@{[BASE_URL]}$link\"><b>&raquo;</b></a></dd>\n";
			}
			print DF "</dl>\n";
		}
	}

	print DF <<EOE;
<p><br>
<hr width="550" size="1" noshade align="left">
generated by <a href="https://github.com/ati/ljsm">ljsm</a> @{[CVSVERSION]}
</body>
</html>
EOE
	close DF or warn "Error closing index.html: $!\n";
	#make_hhp() if ($^O =~ /win32/i);
}


# sort filenames so that the most recent posts go first
sub sort_directory {
	return sort {$b cmp $a} grep (/\w/, @_);
}

# callback subroutine for build_index
#
sub process_html_file {
	my ($line, $link, $kw, $title, $amuser, $itemid, $date, $locallink, $user, $metainfo, $is_utf8);

	return unless ($File::Find::dir =~ m#(\w+)/(\d{4}/\d{1,2}|memories)#);
	$user = $1;
	return unless (-s && /\.html$/);

	# $_ is set to file name and we are inside target directory
	open DF, "<$_" or die "Error opening $File::Find::name for reading: $!\n";

	# search for link, keywords, title and date
	$title = '';
	while ($line = <DF>) {
		$kw = $1 if ($line =~ /<meta name="keywords" content="(.*?)">/);
    $title = $1 if ($line =~ m#<title>(.*): $user</title>#);
		$title = $1 if ($line =~ m#<font face=["']Arial,Helvetica['"] size=['"]?\+1['"]?><i><b>(.*?)</b></i>#i);
		$title = "<i>$1</i>" if ($line =~ m#<span class="heading">Error</span><br />(.*)$#i);
		$title = "<i>$1</i>" if ($line =~ m#^<H1>Error</H1><P>(.*)</P>$#i);
		$date = $1 if (!$date && $line =~ m#href="@{[BASE_URL]}users/\w+/day/\d\d\d\d/\d\d/(\d{1,2})"#);
		$date = $1 if (!$date && $line =~ m#href="@{[BASE_URL]}users/\w+/\d\d\d\d/\d\d/(\d{1,2})/"#);
		$date = $1 if (!$date && $line =~ m#href="http://(?:[-\w]+\.)?@{[BASE_DOMAIN]}/(?:\w+/)?\d\d\d\d/\d\d/(\d{1,2})/"#);
		$users{$1}{$File::Find::name} = 1 if ($line =~ m#userinfo.bml\?user=(\w+)#);
		$is_utf8 = 1 if ($line =~ m#<meta http-equiv="Content-Type" content="text/html; charset=utf-8">#);
	}
	$date = sprintf("%02d. ", $date) if $date;
	$kw = 'default' unless $kw;
	$title = &from_utf8($title) if ($is_utf8 && (UTF8_DECODE || $opt_U));

	$metainfo = {
		'link_type'	=> 'P',
		'filename'	=> $_,
		'title'		=> $title,
		'day'		=> $date,
		'keywords'	=> $kw
	};


	close DF or warn "Error closing $File::Find::name : $!\n";

	if ($File::Find::dir =~ /memories/) { # memories
		$stat{'count_memos'}++;
		$_ =~ m#(\w*)_(\d+)\.html#;
		$metainfo->{'amuser'} = $1;
		$metainfo->{'itemid'} = $2;
		push @{$memories{$kw}}, $metainfo;

	} elsif ($File::Find::name =~ m#(\w+)/(\d{4})/(\d{1,2})/(\d+).html#)  { # posts
		# $1 = user , $2 = year, $3 = month, $4 = itemid $_ = html file name
		$stat{'count_posts'}++;
		$metainfo->{'itemid'} = $4;
		$metainfo->{'amuser'} = $1;
		$posts{$2} = {$3 => []} if (!defined $posts{$2});
		push @{$posts{$2}->{$3}}, $metainfo;
	} else {
		# html file in unknown directory. just do nothing
	}
}

#write files to compile windows help file for given user

=cut

sub make_hhp {
	my ($postid);
	# write main project file
	open DF, ">" . LOCAL_DIR . $user . "/$user.hhp"
		or die "error opening " . LOCAL_DIR . $user . "/$user.hhp" .
				"for writing: $!\n";
	print DF <<EOHHP;
[OPTIONS]
Compatibility=1.1 or later
Compiled file=$user.chm
Contents file=TOC.hhc
Default topic=index.html
Display compile progress=Yes
Full-text search=Yes
Language=0x419 Russian


[FILES]
index.html
EOHHP
	print DF "$postid\n" foreach $postid (keys %metainfo);
	print DF "\n";
	print DF "[INFOTYPES]\n"
	close DF or warn "Error closing $user.hhp: $!\n";

	open DF, ">" . LOCAL_DIR . $user . "/TOC.hhc"
		or die "error opening " . LOCAL_DIR . $user . "/TOC.hhc" .
				"for writing: $!\n";
	print DF <<EOTOC;
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML//EN">
<HTML>
<HEAD>
<meta name="GENERATOR" content="LJSM version @{[CVSVERSION]}">
<!-- Sitemap 1.0 -->
</HEAD><BODY>
<OBJECT type="text/site properties">
	<param name="Window Styles" value="0x800025">
</OBJECT>
<UL>
EOTOC
	#TODO correct nestin of UL and LI elements
	if (scalar keys %posts) {
		foreach $year (reverse sort keys %posts) {
			print DF '
	<LI>
		<OBJECT type="text/sitemap">
			<param name="Name" value="'.$year.'">
		</OBJECT>
		<UL>';
			for  $month (reverse sort {$a <=> $b} keys %{$posts{$year}}) {
				print DF '
			<LI>
				<OBJECT type="text/sitemap">
					<param name="Name" value="'.$month.'">
				</OBJECT>
				<UL>';
				for $postid (@{$posts->{$year}->{$month}}) {
					print DF '
					<LI>
						<OBJECT type="text/sitemap">
							<param name="Name" value="'.$metainfo{$postid}('title'}.'">
							<param name="Local" value="'.$postid.'">
							<param name="ImageNumber" value="39">
						</OBJECT>
					</LI>';
				}
				print DF "\n</UL>\n";
			}
			print DF "\n</LI>\n";
		}
	}

	if (scalar keys %memories) {
	}

	if (scalar keys %users) {
	}
	print DF "</UL>\n</BODY></HTML>";
	close DF or warn "Error closing TOC.hhc: $!\n";
}

=cut


=item lj_interface_query($hashref)

send query to /interface/flat
this function will retry failed HTTP requests for MAX_TRIES times, but
fails immediately if LJ server returns error

=cut
sub lj_interface_query($) {
	my ($form) = @_;

	my ($res);
	foreach (1 .. MAX_TRIES) {
		$res = $ua->post(INTERFACE, $form);
		if ($res->is_success) {
			last;
		} else {
			logmsg("* $_: HTTP error: " . $res->status_line . "\n", 0);
			logmsg("* retrying in 3 seconds...\n", 0);
			sleep 3;
		}
	}
	# 1 = HTTP error
	unless ($res->is_success) {
		logmsg("HTTP request failed after " . MAX_TRIES . " attempts. aborting...\n", 0);
		return (1, undef)
	}

	#warn $res->content . "\n";
	my %lj_response = split(/\n/, $res->content);
	my $code = (defined($lj_response{'success'}) &&
		($lj_response{'success'} eq 'OK') &&
		!defined($lj_response{'errmsg'}))? 0 : 2; # 0 = success, 2 = LJ interface error

	if ($code) {
		logmsg("* LJ interface error.\n", 0);
		logmsg($lj_response{'errmsg'} . "\n", 0) if defined $lj_response{'errmsg'};
	}
	return ($code, \%lj_response);
}


sub tiny_link_extor($$) {
	my ($sref, $img_src) = @_;
	my (@links, $link);

	if ($img_src) {
		while ($$sref =~ m{
			<IMG
			\s+
			[^>]*
			SRC \s* = \s* (["']) (.*?) \1
			[^>]*
			>
		}gsix) {
			$link = $2;
			$link =~ s/\&amp;/&/g;
			push @links, $link;
		}

	} else {
		while ($$sref =~ m{
			<A
			\s+
			[^>]*
			HREF \s* = \s* (["']) (.*?) \1
			[^>]*
			>
		}gsix) {
			$link = $2;
			$link =~ s/\&amp;/&/g;
			push @links, $link;
		}
	}
	return @links;
}


=item from_utf8($string)

convert string from utf8 according to specified encoding
based on function from Guido Socher's Unicode::UTF8simple

=cut
sub from_utf8($){
    my ($str) = @_;

	my %utf2cp = (
		0x0430 => 0xE0, 0x0431 => 0xE1, 0x0432 => 0xE2, 0x0433 => 0xE3, 0x0434 => 0xE4,
		0x0435 => 0xE5, 0x0451 => 0xB8, 0x0436 => 0xE6, 0x0437 => 0xE7, 0x0438 => 0xE8,
		0x0439 => 0xE9, 0x043A => 0xEA, 0x043B => 0xEB, 0x043C => 0xEC, 0x043D => 0xED,
		0x043E => 0xEE, 0x043F => 0xEF, 0x0440 => 0xF0, 0x0441 => 0xF1, 0x0442 => 0xF2,
		0x0443 => 0xF3, 0x0444 => 0xF4, 0x0445 => 0xF5, 0x0446 => 0xF6, 0x0447 => 0xF7,
		0x0448 => 0xF8, 0x0449 => 0xF9, 0x044C => 0xFC, 0x044B => 0xFB, 0x044A => 0xFA,
		0x044D => 0xFD, 0x044E => 0xFE, 0x044F => 0xFF, 0x0410 => 0xC0, 0x0411 => 0xC1,
		0x0412 => 0xC2, 0x0413 => 0xC3, 0x0414 => 0xC4, 0x0415 => 0xC5, 0x0401 => 0xA8,
		0x0416 => 0xC6, 0x0417 => 0xC7, 0x0418 => 0xC8, 0x0419 => 0xC9, 0x041A => 0xCA,
		0x041B => 0xCB, 0x041C => 0xCC, 0x041D => 0xCD, 0x041E => 0xCE, 0x041F => 0xCF,
		0x0420 => 0xD0, 0x0421 => 0xD1, 0x0422 => 0xD2, 0x0423 => 0xD3, 0x0424 => 0xD4,
		0x0425 => 0xD5, 0x0426 => 0xD6, 0x0427 => 0xD7, 0x0428 => 0xD8, 0x0429 => 0xD9,
		0x042C => 0xDC, 0x042B => 0xDB, 0x042A => 0xDA, 0x042D => 0xDD, 0x042E => 0xDE,
		0x042F => 0xDF
	);

	my (@rval, $ubytes, $c, $ent);
	my $multybyte = 0;

	for $c (unpack("C*", $str)){
		if ($c & 128) {
			# 10xxxxxx
			if ((($c & 0xc0) == 128) && $multybyte){
				# last multibyte
				$multybyte--;
				# 63= 111111 = 3f
				$ubytes |= ($c & 63)<< (6*$multybyte);
				if ($multybyte == 0){
					if ($utf2cp{$ubytes}) {
						$ubytes = $utf2cp{$ubytes};
						push(@rval,($ubytes & 0xff));

					} else { # insert HTML entities for undecoded characters
						$ent = sprintf('&#x%x;', $ubytes);
						push @rval, unpack("C*", $ent);
					}
					$ubytes = 0;
				}
				next;
			}
			if (($c & 0xF8 ) == 0xf0){
				# 11110uuu, 11110000=0xf0
				# expect 3 more bytes:
				$multybyte=3;
				# 31= 11111
				$ubytes |= ($c & 7) << 18;
				next;
			} elsif (($c & 0xf0) == 0xe0){
				# 1110zzzz, 0xe0=11100000
				# expect two more bytes:
				$multybyte=2;
				# 31= 11111
				$ubytes |= ($c & 0xf) << 12;
				next;
			} elsif (($c & 0xe0) == 0xc0){
				# 110yyyyy, 192=11000000
				# expect one more byte:
				$multybyte=1;
				# 31= 11111
				$ubytes |= ($c & 31) << 6;
				next;
			}
		} else {
			push(@rval,$c);
			# some encoding error, ignore previous char
			$multybyte=0;
			$ubytes=0;
		}
	}
	return(pack("C*", @rval));
}

sub usage {
	warn <<EOW;
usage:
$0 [-r -m -a -O -I -u user:password -p proxyURL -d yyyy/mm[:yyyy/mm]] user1 user2 ...
$0 -x user1 user2 ...
 -a = save memories AND posts
 -c = save posts without comments
 -r = make sure there's non-empty local file for each post in the date range
 -m = save memories instead of posts
 -O = overwrite existing files (NOT recommended)
 -i [1|2|3] = download icons (1) userpics (2) or all graphics (3) referenced in posts
 -I = ignore network errors and continue fetching posts
 -x = rebuild index file and exit
 -u user:password = specify user:password pair for LJ login on the command prompt
 -U = make UTF-8 to locale charset conversion
 -p proxyURL = use proxyURL as a http proxy
 -d yyyy/mm[:yyyy/mm] = save posts back to the specified date or in the specified date range
 -t = use threader (@{[THREADER]}) for downloading posts with 50 or more comments

@{[CVSVERSION]}
EOW
}

# print some statistics and kiss goodbye
END {
	delete $stat{'count_posts'};
	delete $stat{'count_memos'};
	if ((DEBUG_LEVEL > 0) && (scalar keys %stat)) {
		print "\n\n================ s t a t i s t i c s ====================\n";
		print "ljsm.pl @{[CVSVERSION]}\n";
		print "$stat{$_} $_  " foreach keys %stat;
		print "\n=========================================================\n";
	}
	close LF;
	unlink 'ljsm.log' unless $stat{'pages_err'};
}


