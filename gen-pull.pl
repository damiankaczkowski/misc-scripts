#!/usr/bin/env perl
use strict;
use warnings;
use POSIX;
use Getopt::Long;

my $GIT = "git";
my $Verbose = 1;
my $Sendemail = 0;
my $Start = "";
my $End = "";

# Global variables
my @branches = (
	"soc",
	"soc-arm64",
	"devicetree",
	"devicetree-arm64",
	"maintainers",
	"maintainers-arm64",
	"defconfig",
	"defconfig-arm64",
	"drivers",
);
my @gen_branches;
my $branch_suffix = "next";

my %linux_repo = (
	"url"	=> "http://github.com/Broadcom/stblinux.git",
	"head"	=> "master",
	"base"	=> "1da177e4c3f41524e886b7f1b8a0c1fc7321cac2",
);

my %cclists = (
	"armsoc" => "arm\@kernel.org",
	"base" => ["linux-arm-kernel\@lists.infradead.org",
		   "arnd\@arndb.de",
		   "olof\@lixom.net",
		   "khilman\@kernel.org",
		   "bcm-kernel-feedback-list\@broadcom.com",
	   	  ],
);

sub run($)
{
	my ($cmd) = @_;
	local *F;
	my $ret = "";
	my $err = 0;

	if (!open(F, "$cmd 2>&1 |")) {
		return (-1, "");
	}
	while (<F>) {
		$ret .= $_;
	}
	close(F);

	if (!WIFEXITED($?) || WEXITSTATUS($?)) {
		$err = 1;
	}

	$ret =~ s/[\r\n]+$//;
	return ($err, $ret);
}

sub find_baseline_tag($$) {
	my ($branch, $branch_suffix) = @_;
	my ($err, $commit, $branch_desc, $tag);
	my $head = $linux_repo{head};
	my $end = $branch . "/" . $branch_suffix;

	# Check that the branch exists
	($err, $branch_desc) = run("$GIT rev-parse --verify $end");
	if ($err ne 0) {
		print "No such branch $end\n";
		return;
	}

	($err, $branch_desc) = run("$GIT describe $end");
	if ($Start ne "") {
		$head = $Start . "/" . $branch;
	}
	($err, $commit) = run("$GIT merge-base $head $end");
	return if ($commit eq "");
	($err, $tag) = run("$GIT describe --tags $commit");

	if ($branch_desc eq $tag) {
		return;
	}

	return $tag;
};

sub get_linux_version($) {
	my $tag = shift;
	my ($major, $minor);
	my $base_tag;

	return if !defined($tag) or $tag eq "";

	if ($tag =~ /^v([0-9]).([0-9])(.*)$/) {
		$major = $1;
		$minor = $2;
		# Just assume minor + 1 for now, Linus might change his mind one day
		# though
		$minor += 1;
	} elsif ($tag =~ /^arm-soc\/for-([0-9]).([0-9])(.*)$/) {
		$major = $1;
		$minor = $2;
	} else {
		return undef;
	}

	print " [+] Determined version $major.$minor based on $tag\n" if $Verbose;

	return "$major.$minor";
};

sub uniq {
	my %seen;
	grep !$seen{$_}++, @_;
};

sub get_authors($$) {
	my ($base, $branch) = @_;
	my ($err, $ret) = run("$GIT log $base..$branch");
	my @person_list;
	my @lines = split("\n", $ret);

	foreach my $line (@lines) {
		# Find the author and people CC'd for this commit
		if ($line =~ /(.*)(Author|CC):\s(.*)$/) {
			my $author = $3;
			push @person_list, $author;
		}

		# Now find the contributors to this commit, identified by
		# standard Linux practices
		if ($line =~ /(.*)(Acked|Reviewed|Reported|Signed-off|Suggested|Tested)-by:\s(.*)$/) {
			my $person = $3;
			push @person_list, $person;
		}
	}

	# Now remove non unique entries, since there could be multiple times
	# the same people present in log
	return uniq(@person_list);
};

sub get_num_branches($$) {
	my ($branch, $suffix) = @_;
	my ($err, $ret);
	my $tag = find_baseline_tag($branch, $suffix);

	if (!defined($tag)) {
		print "[-] Branch $branch has no changes\n" if $Verbose;
	} else {
		push @gen_branches, $branch;
	}
};

my $branch_num = 1;

sub usage() {
	print "Usage ".$ARGV[0]. "\n" .
		"--verbose:     enable verbose mode (default: yes)\n" .
		"--send-email:  send emails while processing (default: no)\n" .
		"--start:	start point to give to \"git request-pull\" (default: autodetect)\n" .
		"--end:		end point to give to \"git request-pull\" (default: autodetect)\n" .
		"--help:        this help\n";
	exit(0);
};

GetOptions("verbose" => \$Verbose,
	   "send-email" => \$Sendemail,
	   "start=s" => \$Start,
	   "end=s" => \$End,
	   "help" => \&usage);

sub format_patch($$$$) {
	my ($branch, $suffix, $version, $tag) = @_;
	my ($err, $ret);
	my @authors = get_authors($tag, "$branch/$suffix");
	my @cclist = @{$cclists{"base"}};
	my $output = "";
	my $filename = "$branch_num-$branch.patch";
	my $end = "arm-soc/for-$version/$branch";

	open(my $fh, '>', $filename) or die("Unable to open $filename for write\n");

	print $fh "Subject: [GIT PULL $branch_num/".scalar(@gen_branches)."] Broadcom $branch changes for $version\n";

	# Append the authors we found in the log
	foreach my $author (@authors) {
		print $fh "CC: $author\n";
	}

	# And the usual suspects
	foreach my $cc (@cclist) {
		print $fh "CC: $cc\n";
	};

	print $fh "\n";

	if ($tag =~ /^arm-soc\/for-([0-9]).([0-9])(.*)$/) {
		if ($version eq "$1.$2") {
			$end .= "-part2";
		}
	}

	print "Running pull from $tag to $end\n";

	# TODO, if running with patches appended (-p), we could do a first run
	# which also asks scripts/get_maintainer.pl to tell us who to CC
	($err, $ret) = run("$GIT request-pull $tag $linux_repo{url} $end");
	print $fh $ret;
	close($fh);
};

sub send_email($$) {
	my ($branch, $branch_num) = @_;
	my $filename = "$branch_num-$branch.patch";
	my ($err, $ret) = run("$GIT send-email --to ".$cclists{armsoc}. " --confirm=never $filename");
};

sub do_one_branch($$) {
	my ($branch, $suffix) = @_;
	my $tag = find_baseline_tag($branch, $suffix);

	my $version = get_linux_version($tag);
	die ("unable to get Linux version for $branch") if !defined($version);

	print " [+] Branch $branch is based on $tag, submitting for $version\n" if $Verbose;

	format_patch($branch, $suffix, $version, $tag);

	if ($Sendemail) {
		send_email($branch, $branch_num);
	} else {
		print " [+] Not sending email for $branch\n" if $Verbose;
	}
	$branch_num += 1;

	print "[x] Processed $branch\n" if $Verbose;
};

sub main() {
	my ($err, $ret) = run("$GIT cat-file -e $linux_repo{base}");
	my $branch;
	if ($err) {
	        print " [X] Cannot find a Linux git repo in '".getcwd()."'\n";
	        exit(1);
	}

	# Get the number of branches with changes, some might just be empty
	# Modifies @branches if found empty branches (baseline == branch
	# commit)
	foreach $branch (@branches) {
		get_num_branches("$branch", "$branch_suffix");
	}

	# Now do the actual work of generating the pull request message
	foreach $branch (@gen_branches) {
		do_one_branch("$branch", "$branch_suffix");
	}
};

main();
