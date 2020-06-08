package Hydra::Plugin::GitInput;

use strict;
use parent 'Hydra::Plugin';
use Digest::SHA qw(sha256_hex);
use File::Path;
use Hydra::Helper::Nix;
use Nix::Store;
use Encode;
use Fcntl qw(:flock);
use File::stat;
use Env;
use JSON;
use Data::Dumper;

my $CONFIG_SECTION = "git-input";


sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'git'} = 'Git checkout';
}

sub _isHash {
    my ($rev) = @_;
    return length($rev) == 40 && $rev =~ /^[0-9a-f]+$/;
}

sub _parseValue {
    my ($value) = @_;
    my @parts = split ' ', $value;
    (my $uri, my $branch, my $deepClone) = @parts;
    $branch = defined $branch ? $branch : "master";
    my $options = {};
    my $start_options = 3;
    # if deepClone has "=" then is considered an option
    # and not the enabling of deepClone
    if (index($deepClone, "=") != -1) {
        undef $deepClone;
        $start_options = 2;
    }
    foreach my $option (@parts[$start_options .. $#parts]) {
        (my $key, my $value) = split('=', $option);
        $options->{$key} = $value;
    }
    return ($uri, $branch, $deepClone, $options);
}

sub _printIfDebug {
    my ($msg) = @_;
    print STDERR "GitInput: $msg" if $ENV{'HYDRA_DEBUG'};
}

=item _pluginConfig($main_config, $project_name, $jobset_name, $input_name)

Read the configuration from the main hydra config file.

The configuration is loaded from the "git-input" block.

Current valid configuration settings:

  * timeout :: specifies the timeout period (in seconds) for
               performing remote git operations

  * cache_period :: specifies the timeout period (in seconds) for
                    using cached git information.  This is useful if
                    there are many jobsets that might share the same
                    git input: the first jobset does the actual git
                    fetching and subsequent jobsets evaluated in the
                    cache_period will quickly complete using the
                    cached information.

The variables defined directly in the input value will override
the ones on the configuration file, to define the variables
as an input value use: <name>=<value> without spaces and
specify at least the repo url and branch.

Expected configuration format in the hydra config file:
    <git-input>
      # general timeout
      timeout = 400

      <project:jobset:input-name>
        # specific timeout for a particular input
        timeout = 400
      </project:jobset:input-name>

    </git-input>
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
    if (exists $cfg->{cache_period}) {
        $values->{cache_period} = int($cfg->{cache_period});
        _printIfDebug "Caching fetched git information for $input_block for $values->{cache_period} seconds\n";
    } else {
        _printIfDebug "Caching disabled for fetched git information\n";
    }
    return $values;
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;

    return undef if $type ne "git";

    my ($uri, $branch, $deepClone, $options) = _parseValue($value);
    my $cfg = _pluginConfig($self->{config},
                            $project->get_column('name'),
                            $jobset->get_column('name'),
                            $name);
    # give preference to the options from the input value
    while (my ($opt_name, $opt_value) = each %{$options}) {
        if ($opt_value =~ /^[+-]?\d+\z/) {
            $opt_value = int($opt_value);
        }
        $cfg->{$opt_name} = $opt_value;
        _printIfDebug "'$name': override '$opt_name' with input value: $opt_value\n";
    }

    # Clone or update a branch of the repository into our SCM cache.
    my $cacheDir = getSCMCacheDir . "/git";
    mkpath($cacheDir);
    my $clonePath = $cacheDir . "/" . sha256_hex($uri);
    my $cacheFile = $clonePath . ".cache_" . $branch;

    # Use cached information if available and fresh enough
    if (exists $cfg->{cache_period}) {
        if (-r $cacheFile) {
            my $cacheTime = stat($cacheFile)->mtime;
            my $nowTime = time;
            if ($nowTime - $cacheTime <= $cfg->{cache_period}) {{
                local $/ = undef;
                open my $fh, "<", $cacheFile or last;
                my $data = decode_json(<$fh>);
                if (-e $data->{storePath}) {
                    _printIfDebug "returning cached information for $name ref $branch\n";
                    return $data;
                } else {
                    _printIfDebug "rebuilding Git info for $name ref $branch; store path was GC'd\n";
                    last;
                }
            }}
        }
    }

    open(my $lock, ">", "$clonePath.lock") or die;
    flock($lock, LOCK_EX) or die;

    my $res;
    if (! -d $clonePath) {
        # Clone everything and fetch the branch.
        $res = run(cmd => ["git", "init", $clonePath]);
        $res = run(cmd => ["git", "remote", "add", "origin", "--", $uri], dir => $clonePath) unless $res->{status};
        die "error creating git repo in `$clonePath':\n$res->{stderr}" if $res->{status};
    }

    # This command forces the update of the local branch to be in the same as
    # the remote branch for whatever the repository state is.  This command mirrors
    # only one branch of the remote repository.
    my $localBranch = _isHash($branch) ? "_hydra_tmp" : $branch;
    $res = run(cmd => ["git", "fetch", "-fu", "origin", "+$branch:$localBranch"], dir => $clonePath,
               timeout => $cfg->{timeout});
    $res = run(cmd => ["git", "fetch", "-fu", "origin"], dir => $clonePath, timeout => $cfg->{timeout}) if $res->{status};
    die "error fetching latest change from git repo at `$uri':\n$res->{stderr}" if $res->{status};

    # If deepClone is defined, then we look at the content of the repository
    # to determine if this is a top-git branch.
    if (defined $deepClone) {

        # Is the target branch a topgit branch?
        $res = run(cmd => ["git", "ls-tree", "-r", "$branch", ".topgit"], dir => $clonePath);

        if ($res->{stdout} ne "") {
            # Checkout the branch to look at its content.
            $res = run(cmd => ["git", "checkout", "--force", "$branch"], dir => $clonePath);
            die "error checking out Git branch '$branch' at `$uri':\n$res->{stderr}" if $res->{status};

            # This is a TopGit branch.  Fetch all the topic branches so
            # that builders can run "tg patch" and similar.
            $res = run(cmd => ["tg", "remote", "--populate", "origin"], dir => $clonePath, timeout => $cfg->{timeout});
            print STDERR "warning: `tg remote --populate origin' failed:\n$res->{stderr}" if $res->{status};
        }
    }

    my $timestamp = time;
    my $sha256;
    my $storePath;

    my $revision = _isHash($branch) ? $branch
        : grab(cmd => ["git", "rev-parse", "$branch"], dir => $clonePath, chomp => 1);
    die "did not get a well-formated revision number of Git branch '$branch' at `$uri'"
        unless $revision =~ /^[0-9a-fA-F]+$/;

    # Some simple caching: don't check a uri/branch/revision more than once.
    # TODO: Fix case where the branch is reset to a previous commit.
    my $cachedInput;
    ($cachedInput) = $self->{db}->resultset('CachedGitInputs')->search(
        {uri => $uri, branch => $branch, revision => $revision},
        {rows => 1});

    addTempRoot($cachedInput->storepath) if defined $cachedInput;

    if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
        $storePath = $cachedInput->storepath;
        $sha256 = $cachedInput->sha256hash;
        $revision = $cachedInput->revision;
    } else {
        # Then download this revision into the store.
        print STDERR "checking out Git branch $branch from $uri\n";
        $ENV{"NIX_HASH_ALGO"} = "sha256";
        $ENV{"PRINT_PATH"} = "1";
        $ENV{"NIX_PREFETCH_GIT_LEAVE_DOT_GIT"} = "0";
        $ENV{"NIX_PREFETCH_GIT_DEEP_CLONE"} = "";

        if (defined $deepClone) {
            # Checked out code often wants to be able to run `git
            # describe', e.g., code that uses Gnulib's `git-version-gen'
            # script.  Thus, we leave `.git' in there.
            $ENV{"NIX_PREFETCH_GIT_LEAVE_DOT_GIT"} = "1";

            # Ask for a "deep clone" to allow "git describe" and similar
            # tools to work.  See
            # http://thread.gmane.org/gmane.linux.distributions.nixos/3569
            # for a discussion.
            $ENV{"NIX_PREFETCH_GIT_DEEP_CLONE"} = "1";
        }

        # FIXME: Don't use nix-prefetch-git.
        ($sha256, $storePath) = split ' ', grab(cmd => ["nix-prefetch-git", $clonePath, $revision], chomp => 1);

        # FIXME: time window between nix-prefetch-git and addTempRoot.
        addTempRoot($storePath);

        $self->{db}->txn_do(sub {
            $self->{db}->resultset('CachedGitInputs')->update_or_create(
                { uri => $uri
                , branch => $branch
                , revision => $revision
                , sha256hash => $sha256
                , storepath => $storePath
                });
            });
    }

    # For convenience in producing readable version names, pass the
    # number of commits in the history of this revision (‘revCount’)
    # the output of git-describe (‘gitTag’), and the abbreviated
    # revision (‘shortRev’).
    my $revCount = grab(cmd => ["git", "rev-list", "--count", "$revision"], dir => $clonePath, chomp => 1);
    my $gitTag = grab(cmd => ["git", "describe", "--always", "$revision"], dir => $clonePath, chomp => 1);
    my $shortRev = grab(cmd => ["git", "rev-parse", "--short", "$revision"], dir => $clonePath, chomp => 1);

    my $rdata =
        { uri => $uri
        , storePath => $storePath
        , sha256hash => $sha256
        , revision => $revision
        , revCount => int($revCount)
        , gitTag => $gitTag
        , shortRev => $shortRev
        };

    # If cacheing enabled, cache these results.
    if (exists $cfg->{cache_period}) {{
        _printIfDebug "Caching git information for $name ref $branch into $cacheFile\n";
        open my $ofh, ">", $cacheFile or last;
        print $ofh encode_json($rdata);
        close $ofh;
        cleanup_cachefiles($cfg->{cache_period}, $clonePath);
    }}

    return $rdata;
}

sub cleanup_cachefiles {
    my ($cache_period, $base) = @_;
    # Find all cache files relative to $base (sha from the input's
    # URL) and remove any which exceed the cache period.  The file
    # check in fetchInput will prevent using an old cache file, but
    # this ensures that cache files for refs (e.g. branches) that no
    # longer exist are removed.
    my $files = glob($base . ".cache_*");
    my $now_time = time;
    foreach my $cache_file ($files) {
        if (!defined($cache_file)) { next; } # happens occasionally... why?
        my $cache_time = stat($cache_file)->mtime;
        if ($now_time - $cache_time > $cache_period) {
            unlink $cache_file or next;  # failure on one file doesn't abort cleanup
        }
    }
}

sub getCommits {
    my ($self, $type, $value, $rev1, $rev2) = @_;
    return [] if $type ne "git";

    return [] unless $rev1 =~ /^[0-9a-f]+$/;
    return [] unless $rev2 =~ /^[0-9a-f]+$/;

    my ($uri, $branch, $deepClone) = _parseValue($value);

    my $clonePath = getSCMCacheDir . "/git/" . sha256_hex($uri);

    my $out = grab(cmd => ["git", "log", "--pretty=format:%H%x09%an%x09%ae%x09%at", "$rev1..$rev2"], dir => $clonePath);

    my $res = [];
    foreach my $line (split /\n/, $out) {
        my ($revision, $author, $email, $date) = split "\t", $line;
        push @$res, { revision => $revision, author => decode("utf-8", $author), email => $email };
    }

    return $res;
}

1;
