package Hydra::Controller::Root;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Digest::SHA1 qw(sha1_hex);
use Nix::Store;
use Nix::Config;
use Encode;
use JSON;

# Put this controller at top-level.
__PACKAGE__->config->{namespace} = '';

sub noLoginNeeded {
  my ($c) = @_;

  return $c->request->path eq "persona-login" ||
         $c->request->path eq "login" ||
         $c->request->path eq "logo" ||
         $c->request->path =~ /^static\//;
}


sub begin :Private {
    my ($self, $c, @args) = @_;

    $c->stash->{curUri} = $c->request->uri;
    $c->stash->{version} = $ENV{"HYDRA_RELEASE"} || "<devel>";
    $c->stash->{nixVersion} = $ENV{"NIX_RELEASE"} || "<devel>";
    $c->stash->{curTime} = time;
    $c->stash->{logo} = defined $c->config->{hydra_logo} ? "/logo" : "";
    $c->stash->{tracker} = $ENV{"HYDRA_TRACKER"};
    $c->stash->{flashMsg} = $c->flash->{flashMsg};
    $c->stash->{successMsg} = $c->flash->{successMsg};
    $c->stash->{personaEnabled} = $c->config->{enable_persona} // "0" eq "1";

    $c->stash->{isPrivateHydra} = $c->config->{private} // "0" ne "0";

    if ($c->stash->{isPrivateHydra} && ! noLoginNeeded($c)) {
        requireUser($c);
    }

    if (scalar(@args) == 0 || $args[0] ne "static") {
        $c->stash->{nrRunningBuilds} = $c->model('DB::Builds')->search({ finished => 0, busy => 1 }, {})->count();
        $c->stash->{nrQueuedBuilds} = $c->model('DB::Builds')->search({ finished => 0 })->count();
    }

    # Gather the supported input types.
    $c->stash->{inputTypes} = {
        'string' => 'String value',
        'boolean' => 'Boolean',
        'nix' => 'Nix expression',
        'build' => 'Previous Hydra build',
        'sysbuild' => 'Previous Hydra build (same system)',
        'eval' => 'Previous Hydra evaluation'
    };
    $_->supportedInputTypes($c->stash->{inputTypes}) foreach @{$c->hydra_plugins};

    $c->forward('deserialize');

    $c->stash->{params} = $c->request->data or $c->request->params;
    unless (defined $c->stash->{params} and %{$c->stash->{params}}) {
        $c->stash->{params} = $c->request->params;
    }
}

sub deserialize :ActionClass('Deserialize') { }


sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'overview.tt';
    $c->stash->{projects} = [$c->model('DB::Projects')->search(isAdmin($c) ? {} : {hidden => 0}, {order_by => 'name'})];
    $c->stash->{newsItems} = [$c->model('DB::NewsItems')->search({}, { order_by => ['createtime DESC'], rows => 5 })];
    $self->status_ok($c,
        entity => $c->stash->{projects}
    );
}


sub queue :Local :Args(0) :ActionClass('REST') { }

sub queue_GET {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue.tt';
    $c->stash->{flashMsg} //= $c->flash->{buildMsg};
    $self->status_ok(
        $c,
        entity => [$c->model('DB::Builds')->search({finished => 0}, { order_by => ["globalpriority desc", "id"]})]
    );
}


sub status :Local :Args(0) :ActionClass('REST') { }

sub status_GET {
    my ($self, $c) = @_;
    $self->status_ok(
        $c,
        entity => [$c->model('DB::Builds')->search({finished => 0, busy => 1}, { order_by => ["priority DESC", "id"]})]
    );
}


sub machines :Local Args(0) {
    my ($self, $c) = @_;
    my $machines = getMachines;

    # Add entry for localhost.
    $machines->{''} //= {};
    delete $machines->{'localhost'};

    my $status = $c->model('DB::SystemStatus')->find("queue-runner");
    if ($status) {
        my $ms = decode_json($status->status)->{"machines"};
        foreach my $name (keys %{$ms}) {
            $name = "" if $name eq "localhost";
            $machines->{$name} //= {disabled => 1};
            $machines->{$name}->{nrStepsDone} = $ms->{$name}->{nrStepsDone};
            $machines->{$name}->{avgStepBuildTime} = $ms->{$name}->{avgStepBuildTime} // 0;
        }
    }

    $c->stash->{machines} = $machines;
    $c->stash->{steps} = [ $c->model('DB::BuildSteps')->search(
        { finished => 0, 'me.busy' => 1, 'build.busy' => 1, },
        { join => [ 'build' ]
        , order_by => [ 'machine', 'stepnr' ]
        } ) ];
    $c->stash->{template} = 'machine-status.tt';
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('/') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->model('DB::Builds');
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceeded');
    $c->stash->{channelBaseName} = "everything";
    $c->stash->{total} = $c->model('DB::NrBuilds')->find('finished')->count;
}


sub robots_txt : Path('robots.txt') {
    my ($self, $c) = @_;

    sub uri_for {
        my ($c, $controller, $action, @args) = @_;
        return $c->uri_for($c->controller($controller)->action_for($action), @args)->path;
    }

    sub channelUris {
        my ($c, $controller, $bindings) = @_;
        return
            ( uri_for($c, $controller, 'closure', $bindings, "*")
            , uri_for($c, $controller, 'manifest', $bindings)
            , uri_for($c, $controller, 'pkg', $bindings, "*")
            , uri_for($c, $controller, 'nixexprs', $bindings)
            , uri_for($c, $controller, 'channel_contents', $bindings)
            );
    }

    # Put actions that are expensive or not useful for indexing in
    # robots.txt.  Note: wildcards are not universally supported in
    # robots.txt, but apparently Google supports them.
    my @rules =
        ( uri_for($c, 'Build', 'build', ["*"])
        , uri_for($c, 'Root', 'nar', [], "*")
        , uri_for($c, 'Root', 'status', [])
        , uri_for($c, 'Root', 'all', [])
        , uri_for($c, 'Root', 'queue', [])
        , uri_for($c, 'API', 'scmdiff', [])
        , uri_for($c, 'API', 'logdiff', [],"*", "*")
        , uri_for($c, 'Project', 'all', ["*"])
        , uri_for($c, 'Jobset', 'all', ["*", "*"])
        , uri_for($c, 'Job', 'all', ["*", "*", "*"])
        , channelUris($c, 'Root', ["*"])
        , channelUris($c, 'Project', ["*", "*"])
        , channelUris($c, 'Jobset', ["*", "*", "*"])
        , channelUris($c, 'Job', ["*", "*", "*", "*"])
        );

    $c->stash->{'plain'} = { data => "User-agent: *\n" . join('', map { "Disallow: $_\n" } @rules) };
    $c->forward('Hydra::View::Plain');
}


sub default :Path {
    my ($self, $c) = @_;
    notFound($c, "Page not found.");
}


sub end : ActionClass('RenderView') {
    my ($self, $c) = @_;

    if (defined $c->stash->{json}) {
        if (scalar @{$c->error}) {
            # FIXME: dunno why we need to do decode_utf8 here.
            $c->stash->{json}->{error} = join "\n", map { decode_utf8($_); } @{$c->error};
            $c->clear_errors;
        }
        $c->forward('View::JSON');
    }

    elsif (scalar @{$c->error}) {
        $c->stash->{resource} = { error => join "\n", @{$c->error} };
        $c->stash->{template} = 'error.tt';
        $c->stash->{errors} = $c->error;
        $c->response->status(500) if $c->response->status == 200;
        if ($c->response->status >= 300) {
            $c->stash->{httpStatus} =
                $c->response->status . " " . HTTP::Status::status_message($c->response->status);
        }
        $c->clear_errors;
    }

    $c->forward('serialize') if defined $c->stash->{resource};
}


sub serialize : ActionClass('Serialize') { }


sub nar :Local :Args(1) {
    my ($self, $c, $path) = @_;

    $path = ($ENV{NIX_STORE_DIR} || "/nix/store")."/$path";

    gone($c, "Path " . $path . " is no longer available.") unless isValidPath($path);

    $c->stash->{current_view} = 'NixNAR';
    $c->stash->{storePath} = $path;
}


sub nix_cache_info :Path('nix-cache-info') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('text/plain');
    $c->stash->{plain}->{data} =
        #"StoreDir: $Nix::Config::storeDir\n" . # FIXME
        "StoreDir: " . ($ENV{NIX_STORE_DIR} || "/nix/store") . "\n" .
        "WantMassQuery: 0\n" .
        # Give Hydra binary caches a very low priority (lower than the
        # static binary cache http://nixos.org/binary-cache).
        "Priority: 100\n";
    setCacheHeaders($c, 24 * 60 * 60);
    $c->forward('Hydra::View::Plain');
}


sub narinfo :LocalRegex('^([a-z0-9]+).narinfo$') :Args(0) {
    my ($self, $c) = @_;
    my $hash = $c->req->captures->[0];

    die if length($hash) != 32;
    my $path = queryPathFromHashPart($hash);

    if (!$path) {
        $c->response->status(404);
        $c->response->content_type('text/plain');
        $c->stash->{plain}->{data} = "does not exist\n";
        $c->forward('Hydra::View::Plain');
        setCacheHeaders($c, 60 * 60);
        return;
    }

    $c->stash->{storePath} = $path;
    $c->forward('Hydra::View::NARInfo');
}


sub logo :Local {
    my ($self, $c) = @_;
    my $path = $c->config->{hydra_logo} // die("Logo not set!");
    $c->serve_static_file($path);
}


sub evals :Local Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'evals.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    my $evals = $c->model('DB::JobsetEvals');

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{total} = $evals->search({hasnewbuilds => 1})->count;
    $c->stash->{evals} = getEvals($self, $c, $evals, ($page - 1) * $resultsPerPage, $resultsPerPage)
}


sub steps :Local Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'steps.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{steps} = [ $c->model('DB::BuildSteps')->search(
        { starttime => { '!=', undef },
          stoptime => { '!=', undef }
        },
        { order_by => [ "stoptime desc" ],
          rows => $resultsPerPage,
          offset => ($page - 1) * $resultsPerPage
        }) ];

    $c->stash->{total} = approxTableSize($c, "IndexBuildStepsOnStopTime");
}


sub search :Local Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'search.tt';

    my $query = trim $c->request->params->{"query"};

    error($c, "Query is empty.") if $query eq "";
    error($c, "Invalid character in query.")
        unless $query =~ /^[a-zA-Z0-9_\-\/.]+$/;

    $c->stash->{limit} = 500;

    $c->stash->{projects} = [ $c->model('DB::Projects')->search(
        { -and =>
            [ { -or => [ name => { ilike => "%$query%" }, displayName => { ilike => "%$query%" }, description => { ilike => "%$query%" } ] }
            , { hidden => 0 }
            ]
        },
        { order_by => ["name"] } ) ];

    $c->stash->{jobsets} = [ $c->model('DB::Jobsets')->search(
        { -and =>
            [ { -or => [ "me.name" => { ilike => "%$query%" }, "me.description" => { ilike => "%$query%" } ] }
            , { "project.hidden" => 0, "me.hidden" => 0 }
            ]
        },
        { order_by => ["project", "name"], join => ["project"] } ) ];

    $c->stash->{jobs} = [ $c->model('DB::Jobs')->search(
        { "me.name" => { ilike => "%$query%" }
        , "project.hidden" => 0
        , "jobset.hidden" => 0
        },
        { order_by => ["enabled_ desc", "project", "jobset", "name"], join => ["project", "jobset"]
        , "+select" => [\ "(project.enabled = 1 and jobset.enabled = 1 and exists (select 1 from Builds where project = project.name and jobset = jobset.name and job = me.name and iscurrent = 1)) as enabled_"]
        , "+as" => ["enabled"]
        , rows => $c->stash->{limit} + 1
        } ) ];

    # Perform build search in separate queries to prevent seq scan on buildoutputs table.
    $c->stash->{builds} = [ $c->model('DB::Builds')->search(
        { "buildoutputs.path" => trim($query) },
        { order_by => ["id desc"], join => ["buildoutputs"] } ) ];

    $c->stash->{buildsdrv} = [ $c->model('DB::Builds')->search(
        { "drvpath" => trim($query) },
        { order_by => ["id desc"] } ) ];
}


sub log :Local :Args(1) {
    my ($self, $c, $path) = @_;

    $path = ($ENV{NIX_STORE_DIR} || "/nix/store")."/$path";

    my @outpaths = ($path);
    my $logPath = findLog($c, $path, @outpaths);
    notFound($c, "The build log of $path is not available.") unless defined $logPath;

    $c->stash->{logPath} = $logPath;
    $c->forward('Hydra::View::NixLog');
}


1;
