package Hydra::Plugin::EmailNotification;

use utf8;
use strict;
use parent 'Hydra::Plugin';
use POSIX qw(strftime);
use List::Util qw(max);
use Template;
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Email;


my $template = <<EOF;
Hi,

The status of Hydra job ‘[% showJobName(build) %]’ [% IF showSystem %](on [% build.system %]) [% END %][% IF prevBuild && build.buildstatus != prevBuild.buildstatus %]has changed from "[% showStatus(prevBuild) %]" to "[% showStatus(build) %]"[% ELSE %]is "[% showStatus(build) %]"[% END %].  For details, see

  [% baseurl %]/build/[% build.id %]

Failed [% failSteps.size %] steps:
[% FOREACH s IN failSteps -%]
    * [% s %]
[% END -%]

[% IF dependents.size > 0 -%]
The following dependent jobs also failed:

[% FOREACH b IN dependents -%]
* [% showJobName(b) %] ([% baseurl %]/build/[% b.id %])
[% END -%]

[% END -%]
[% IF nrCommits > 0 && authorList -%]
This may be due to [% IF nrCommits > 1 -%][% nrCommits %] commits[%- ELSE -%]a commit[%- END -%] by [% authorList %].

[% END -%]
[% IF build.buildstatus == 0 -%]
Yay!
[% ELSE -%]
[% IF notificationsTo.size > 1 %]
Notifications have also been sent to [% notificationsTo.size - 1 %] other [% IF notificationsTo.size != 2 %]people[% ELSE %]person[% END %]:
[% FOREACH t IN notificationsTo -%]
    [% t %]
[% END %]
[% END %]

Changes:
[% FOREACH ichg IN inputChanges.keys.sort -%]
    * [% ichg %]:[% fill.substr(0, longest - ichg.length) %] [% inputChanges.\$ichg %]
[% END %]

Go forth and fix [% IF dependents.size == 0 -%]it[% ELSE %]them[% END %].
[% END -%]

Regards,

The Hydra build daemon.
EOF


sub rValue {  # like common.tt renderShortInputValue
    my ($input) = @_;
    if ($input->type eq "build" || $input->type eq "sysbuild") {
        "Build ".$input->dependency->id;
    } elsif ($input->type eq "string") {
        '"'.$input->value.'"';
    } elsif ($input->type eq "nix" || $input->type eq "boolean") {
        $input->value;
    } else {
        if ($input->revision) {
            $input->uri." (r".$input->revision.")";
        } else {
            $input->uri;
        }
    }
}
sub rDelta {
    my ($oldval, $newval) = @_;
    "$oldval to $newval";
}

sub buildFinished {
    my ($self, $build, $dependents) = @_;

    return unless $self->{config}->{email_notification} // 0;

    die unless $build->finished;

    # Figure out to whom to send notification for each build.  For
    # each email address, we send one aggregate email listing only the
    # relevant builds for that address.
    my %addresses;
    foreach my $b ($build, @{$dependents}) {
        my $prevBuild = getPreviousBuild($b);
        # Do we want to send mail for this build?
        unless ($ENV{'HYDRA_FORCE_SEND_MAIL'}) {
            next unless $b->jobset->enableemail;

            # If build is cancelled or aborted, do not send email.
            next if $b->buildstatus == 4 || $b->buildstatus == 3;

            # If there is a previous (that is not cancelled or aborted) build
            # with same buildstatus, do not send email.
            next if defined $prevBuild && ($b->buildstatus == $prevBuild->buildstatus);
        }

        my $to = $b->jobset->emailoverride ne "" ? $b->jobset->emailoverride : $b->maintainers;

        foreach my $address (split ",", ($to // "")) {
            $address = trim $address;

            $addresses{$address} //= { builds => [] };
            push @{$addresses{$address}->{builds}}, $b;
        }
    }

    my ($authors, $nrCommits, $emailable_authors) = getResponsibleAuthors($build, $self->{plugins});
    my $authorList;
    my $prevBuild = getPreviousBuild($build);
    if (scalar keys %{$authors} > 0 &&
        ((!defined $prevBuild) || ($build->buildstatus != $prevBuild->buildstatus))) {
        my @x = map { "$_ <$authors->{$_}>" } (sort keys %{$authors});
        $authorList = join(" or ", scalar @x > 1 ? join(", ", @x[0..scalar @x - 2]): (), $x[-1]);
        $addresses{$_} = { builds => [ $build ] } foreach (@{$emailable_authors});
    }
    my @steps = map {$_->buildstepoutputs} ($build->buildsteps->search(
                                                {busy => 0, status => { '!=', 0 }},
                                                {order_by => "stepnr desc"}));
    my @stepnames = map {$_->path} @steps;

    my $thisEval = getFirstEval($build);
    my $prevEval = $thisEval->jobset->jobsetevals->search(
        { hasnewbuilds => 1, id => { '<', $thisEval->id } },
        { order_by => "id DESC", rows => 1 })->first;

    my %iChng;
    foreach my $bi1 ($prevEval->jobsetevalinputs) {
        my $deletedInput = 1;
        foreach my $bi2 ($thisEval->jobsetevalinputs) {
            next unless ($bi1->name eq $bi2->name);
            if ($bi1->type eq $bi2->type) {
                if ($bi1->value ne $bi2->value || $bi1->uri ne $bi2->uri) {
                    $iChng{$bi1->name} = rDelta(rValue($bi1), rValue($bi2));
                } elsif ($bi1->uri eq $bi2->uri && $bi1->revision ne $bi2->revision) {
                    if ($bi1->type eq "git") {
                        $iChng{$bi1->name} = rDelta(substr($bi1->revision,0,6),
                                                    substr($bi2->revision,0,6));
                    } else {
                        $iChng{$bi1->name} = rDelta($bi1->revision, $bi2->revision);
                    }
                } elsif (($bi1->dependency && $bi2->dependency &&
                          $bi1->dependency->id != $bi2->dependency->id) ||
                         $bi1->path ne $bi2->path) {
                    $iChng{$bi1->name} = rDelta(rValue($bi1), rValue($bi2));
                }
            } else {
                $iChng{$bi1->name} = rDelta(rValue($bi1), rValue($bi2));
            }
            $deletedInput = 0;
            last;
        }
        if ($deletedInput == 1) {
            $iChng{$bi1->name} = "Input not present in this build";
        }
    }
    foreach my $bi2 ($thisEval->jobsetevalinputs) {
        my $newInput = 1;
        foreach my $bi1 ($prevEval->jobsetevalinputs) {
            next if ($bi1->name != $bi2->name);
            $newInput = 0;
            last;
        }
        if ($newInput) {
            $iChng{$bi2->name} = "New input in this build";
        }
    }

    my $longestInputName = max (map { length $_ } (keys %iChng));

    # Send an email to each interested address.
    for my $to (keys %addresses) {
        print STDERR "sending mail notification to ", $to, "\n";
        my @builds = @{$addresses{$to}->{builds}};

        my $tt = Template->new({});

        my $vars =
            { build => $build, prevBuild => getPreviousBuild($build)
            , dependents => [grep { $_->id != $build->id } @builds]
            , baseurl => getBaseUrl($self->{config})
            , showJobName => \&showJobName, showStatus => \&showStatus
            , showSystem => index($build->job->name, $build->system) == -1
            , nrCommits => $nrCommits
            , authorList => $authorList
            , failSteps => \@stepnames
            , notificationsTo => [(keys %addresses)]
            , inputChanges => \%iChng
            , longest => $longestInputName
            , fill => "                                        "
            };

        my $body;
        $tt->process(\$template, $vars, \$body)
            or die "failed to generate email from template";

        # stripping trailing spaces from lines
        $body =~ s/[\ ]+$//gm;

        my $subject =
            showStatus($build) . ": Hydra job " . showJobName($build)
            . ($vars->{showSystem} ? " on " . $build->system : "")
            . (scalar @{$vars->{dependents}} > 0 ? " (and " . scalar @{$vars->{dependents}} . " others)" : "");

        sendEmail(
            $self->{config}, $to, $subject, $body,
            [ 'X-Hydra-Project'  => $build->project->name,
            , 'X-Hydra-Jobset'   => $build->jobset->name,
            , 'X-Hydra-Job'      => $build->job->name,
            , 'X-Hydra-System'   => $build->system
            ]);
    }
}


1;
