package Hydra::Plugin::GitTree;

use strict;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use File::Path;
use File::Temp;
use JSON;
use Hydra::Helper::Nix;
use Nix::Store;
use Encode;
use Fcntl qw(:flock);
use Env;
use Data::Dumper;
use Config::IniFiles;

my $CONFIG_SECTION = "git-tree";

##
## The GitTree plugin doesn't fetch the repo itself (permanently) but
## it determines the current revision, the checksum, and the revisions
## and checksums of all the .gitmodules submodules.  This information
## should be useable by an evaluation to generate a declarative input
## to build the target repo and the associated submodules.

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'gittree'} = 'Git repo tree information';
}

sub _isHash {
    my ($rev) = @_;
    return length($rev) == 40 && $rev =~ /^[0-9a-f]+$/;
}

sub _parseValue {
    my ($value) = @_;
    my @parts = split ' ', $value;
    (my $uri, my $branch) = @parts[0..1];
    my $partstart = (defined $branch && index($branch, '=') == -1) ? 2 : 1;
    $branch = (defined $branch && (index($branch, '=') == -1)) ? $branch : "master";
    my $gitref_overrides = {};
    my $options = {};
    if (@parts > $partstart) {
        foreach my $part (@parts[$partstart..$#parts]) {
            (my $ref, my $ovrrd) = split('=', $part);
            $gitref_overrides->{$ref} = $ovrrd;
        }
    }
    return ($uri, $branch, $gitref_overrides, $options);
}

sub _printIfDebug {
    my ($msg) = @_;
    print STDERR "GitTree: $msg" if $ENV{'HYDRA_DEBUG'};
}

=item _pluginConfig($main_config, $project_name, $jobset_name, $input_name)

Read the configuration from the main hydra config file.

The configuration is loaded from the "git-info" block.

Currently only the "timeout" variable is been looked up in the file.

The variables defined directly in the input value will override
the ones on the configuration file, to define the variables
as an input value use: <name>=<value> without spaces and
specify at least the repo url and branch.

Expected configuration format in the hydra config file:
    <git-info>
      # general timeout
      timeout = 400

      <project:jobset:input-name>
        # specific timeout for a particular input
        timeout = 400
      </project:jobset:input-name>

    </git-info>

Corresponding input specification
    Input name: git-foo
    Type: Git repo information
    Value: https://github.com/foo/repo.git develop timeout=400

=cut
sub _pluginConfig {
    my ($main_config, $project_name, $jobset_name, $input_name) = @_;
    my $cfg = $main_config->{$CONFIG_SECTION};
    # default values
    my $values = {
        timeout => 600,
    };
    my $input_block = "$project_name:$jobset_name:$input_name";

    unless (defined $cfg) {
        _printIfDebug "Unable to load $CONFIG_SECTION section\n";
        _printIfDebug "Using default values\n";
        return $values;
    } else {
        _printIfDebug "Parsing plugin configuration:\n";
        _printIfDebug Dumper($cfg);
    }
    if (defined $cfg->{$input_block} and %{$cfg->{$input_block}}) {
         _printIfDebug "Merging sections from $input_block\n";
         # merge with precedence to the input block
        $cfg = {%{$cfg}, %{$cfg->{$input_block}}};
    }
    if (exists $cfg->{timeout}) {
        $values->{timeout} = int($cfg->{timeout});
        _printIfDebug "Using custom timeout for $input_block:\n";
    } else {
        _printIfDebug "Using default timeout for $input_block:\n";
    }
    _printIfDebug "$values->{timeout}\n";
    return $values;
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;

    return undef if $type ne "gittree";

    my ($uri, $branch, $gitref_overrides, $options) = _parseValue($value);
    my $cfg = _pluginConfig($self->{config},
                            $project->get_column('name'),
                            $jobset->get_column('name'),
                            $name);
    # give preference to the options from the input value
    while (my ($opt_name, $opt_value) = each %{$options}) {
        if ($opt_value =~ /\d+/) {
            $opt_value = int($opt_value);
        }
        $cfg->{$opt_name} = $opt_value;
        _printIfDebug "'$name': override '$opt_name' with input value: $opt_value\n";
    }

    my $gtree = getGitTree($uri, $branch, $gitref_overrides, $cfg->{timeout});

    my $storePath = addTreeToStore($uri, $gtree);
    my $rev = $gtree->{revision};
    # my $timestamp = time;
    # my $rev = strftime("%Y%m%d%H%M%S", gmtime($timestamp));

    return { storePath => $storePath, revision => $rev };
}


sub getGitTree {
    my ($uri, $branch, $gitref_overrides, $timeout) = @_;

    # Clone or update a branch of the repository into our SCM cache.
    my $cacheDir = getSCMCacheDir . "/gittree";  # avoid colliding with GitInput
    mkpath($cacheDir);
    my $clonePath = $cacheDir . "/" . sha256_hex($uri);

    open(my $lock, ">", "$clonePath.lock") or die;
    flock($lock, LOCK_EX) or die;

    my $res;
    if (! -d $clonePath) {
        # Clone at the branch.
        my $useURI = defined $gitref_overrides->{$uri} ? $gitref_overrides->{$uri} : $uri;
        $res = run(cmd => ["git", "clone", $useURI, $clonePath]);
        if ($res->{status} &&
            index($res->{stderr}, "git@") != -1 &&
            index($res->{stderr}, "Permission denied (publickey)") != -1) {
            $uri =~ s,^git\@([^:]+):,https://$1/,;
            $res = run(cmd => ["git", "clone", $uri, $clonePath]);
        }
        die "error $res->{status} creating git repo in `$clonePath' from $useURI:\n$res->{stderr}\n" if $res->{status};
    } else {
        $res = run(cmd => ["git", "checkout", "-f", "master"], dir => $clonePath);
        die "error $res->{status} checking out master in git repo in `$clonePath' (remote $uri):\n$res->{stderr}\n" if $res->{status};
        $res = run(cmd => ["git", "pull", "--recurse-submodules=no", "origin", "master:master"], dir => $clonePath);
        die "error $res->{status} updating git repo in `$clonePath' (remote $uri):\n$res->{stderr}\n" if $res->{status};
    }
    $res1 = run(cmd => ["git", "checkout", $branch], dir => $clonePath, chomp => 1);
    if ($res1->{status}) {
        $res = run(cmd => ["git", "checkout", "-B", $branch, "--track", "origin/$branch"],
                   dir => $clonePath, chomp => 1);
    } else {
        $res = $res;
    }
    die "errors updating local git cache in $clonePath:\n * $res1->{status} checking out reference $branch\n\n$res1->{stderr}\n\n * $res->{status} checking out branch $branch\n\n$res->{stderr}\n" if $res->{status};

    my $timestamp = time;
    # my $sha256;
    # my $storePath;

    my $revision = _isHash($branch) ? $branch
                   : grab(cmd => ["git", "rev-parse", $branch], dir => $clonePath, chomp => 1);
    die "did not get a well-formated revision number of Git branch '$branch' at `$uri'\n"
        unless $revision =~ /^[0-9a-fA-F]+$/;

    # For convenience in producing readable version names, pass the
    # number of commits in the history of this revision (‘revCount’)
    # the output of git-describe (‘gitTag’), and the abbreviated
    # revision (‘shortRev’).
    my $revCount = grab(cmd => ["git", "rev-list", "--count", $revision], dir => $clonePath, chomp => 1);
    my $gitTag = grab(cmd => ["git", "describe", "--always", $revision], dir => $clonePath, chomp => 1);
    my $shortRev = grab(cmd => ["git", "rev-parse", "--short", $revision], dir => $clonePath, chomp => 1);

    my $submodules = [];

    if (-f "$clonePath/.gitmodules") {
        my %gitmodules;
        tie %gitmodules, 'Config::IniFiles', ( -file => "$clonePath/.gitmodules" );
        # The gitmodules file has a number of entries in config-ini style:
        #   [submodule "NAME"]
        #     path = LOCAL-PATH-TO-CHECKOUT
        #     url = URL-TO-FETCH-SUBMODULE
        # Many specifications use the same value for LOCAL-PATH-TO-CHECKOUT and NAME.

        my $submods = grab(cmd => ["git", "submodule", "status"], dir => $clonePath, chomp => 1);
        # the submodule status command reports a list of "-HASH LOCAL-PATH-TO-CHECKOUT" lines.

        foreach my $line (split /\n/, $submods) {
            my ($revref, $modpath) = split " ", $line;
            my $revision = substr($revref, 1);

            foreach my $section (keys %gitmodules) {
                if ($gitmodules{$section}{"path"} eq $modpath) {
                    my $suburi = $gitmodules{$section}{"url"};
                    my $subinfo = getGitTree($suburi, $revision, $gitref_overrides, $timeout);
                    $subinfo->{submodule} = $modpath;
                    push @$submodules, $subinfo;
                    last;
                }
            }
        }
    }

    return { uri => $uri
           # , storePath => $storePath
           # , sha256hash => $sha256
           , revision => $revision
           , revCount => int($revCount)
           , gitTag => $gitTag
           , shortRev => $shortRev
           , submods => $submodules
        };
}


sub addTreeToStore {
    my ($uri, $tree) = @_;

    my $tempdir = File::Temp->newdir("gittree" . "XXXXX", TMPDIR => 1);
    my $outPath = $tempdir . "/" . "tree"; # sha256_hex($tree->{uri}) . "-tree";

    open(my $outf, ">", $outPath) or die;
    # print $outf encode_json $tree;
    # Use canonical to sort the keys and therefore ensure stability in the output.
    print $outf (JSON->new->utf8->pretty->canonical->encode($tree));
    close $outf;

    my $finalPath = run(cmd => ["nix-store", "--add", "$outPath"], chomp => 1);
    die "error $finalPath->{status} storing $outPath in store:\n$finalPath->{stderr}\n" if $finalPath->{status};

    return $finalPath->{stdout};
}
