use strict;
use warnings FATAL => 'all';

use Test::More;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use Test::DZil;
use Test::Deep;
use Path::Tiny;
use Capture::Tiny 'capture';

{
    package Dist::Zilla::Plugin::BogusInstaller;
    use Moose;
    with 'Dist::Zilla::Role::InstallTool';
    sub setup_installer { }
}

{
    my $tzil = Builder->from_config(
        { dist_root => 't/does_not_exist' },
        {
            add_files => {
                path(qw(source dist.ini)) => simple_ini(
                    'BogusInstaller',
                    'MakeMaker::Fallback',
                ),
            },
        },
    );

    $tzil->chrome->logger->set_debug(1);
    like(
        exception { $tzil->build },
        qr/\Q[MakeMaker::Fallback] No Build.PL found to fall back from!\E/,
        'build aborted when no additional installer is provided',
    );

    diag 'got log messages: ', explain $tzil->log_messages
        if not Test::Builder->new->is_passing;
}

foreach my $eumm_version ('6.00', '0')
{
    my $tzil = Builder->from_config(
        { dist_root => 't/does_not_exist' },
        {
            add_files => {
                path(qw(source dist.ini)) => simple_ini(
                    # in [MakeMaker] 5.019 and earlier, this defaults to 6.30,
                    # and must be set to a number (not empty string) for
                    # Makefile.PL to come out right.
                    [ 'MakeMaker::Fallback' => { eumm_version => $eumm_version } ],
                    [ 'ModuleBuildTiny' ],
                    [ Prereqs => ConfigureRequires => { perl => '5.006' } ],
                ),
            },
        },
    );

    $tzil->chrome->logger->set_debug(1);
    is(
        exception { $tzil->build },
        undef,
        'build proceeds normally',
    );

    my $build_dir = path($tzil->tempdir)->child('build');

    my @expected_files = qw(
        Build.PL
        Makefile.PL
    );

    my @found_files;
    my $iter = $build_dir->iterator({ recurse => 1 });
    while (my $path = $iter->())
    {
        push @found_files, $path->relative($build_dir)->stringify if -f $path;
    }

    cmp_deeply(
        \@found_files,
        bag(@expected_files),
        'both Makefile.PL and Build.PL are generated',
    );

    my $Makefile_PL = path($tzil->tempdir)->child('build', 'Makefile.PL');
    my $Makefile_PL_content = $Makefile_PL->slurp_utf8;

    unlike($Makefile_PL_content, qr/[^\S\n]\n/m, 'no trailing whitespace in generated Makefile.PL');

    my $preamble = join('', <*Dist::Zilla::Plugin::MakeMaker::Fallback::DATA>);
    like($Makefile_PL_content, qr/\Q$preamble\E/ms, 'preamble is found in Makefile.PL');

    unlike(
        $Makefile_PL_content,
        qr/use\s+ExtUtils::MakeMaker\s/m,
        'ExtUtils::MakeMaker not used with VERSION (when '
            . ($eumm_version ? 'a' : 'no')
            . ' eumm_version was specified)',
    );

    like(
        $Makefile_PL_content,
        qr/^use ExtUtils::MakeMaker;$/m,
        'ExtUtils::MakeMaker is still used (when '
            . ($eumm_version ? 'a' : 'no')
            . ' eumm_version was specified)',
    );

    SKIP:
    {
        ok($Makefile_PL_content =~ /^my %configure_requires = \($/mg, 'found start of %configure_requires declaration')
            or skip 'failed to test %configure_requires section', 2;
        my $start = pos($Makefile_PL_content);

        ok($Makefile_PL_content =~ /\);$/mg, 'found end of %configure_requires declaration')
            or skip 'failed to test %configure_requires section', 1;
        my $end = pos($Makefile_PL_content);

        my $configure_requires_content = substr($Makefile_PL_content, $start, $end - $start - 2);

        my %configure_requires = %{ $tzil->distmeta->{prereqs}{configure}{requires} };
        foreach my $prereq (sort keys %configure_requires)
        {
            if ($prereq eq 'perl')
            {
                unlike(
                    $configure_requires_content,
                    qr/perl/m,
                    '%configure_requires does not contain perl',
                );
            }
            else
            {
                like(
                    $configure_requires_content,
                    qr/$prereq\W+$configure_requires{$prereq}\W/m,
                    "\%configure_requires contains $prereq => $configure_requires{$prereq}",
                );
            }
        }
        is($configure_requires{'ExtUtils::MakeMaker'}, $eumm_version // 0, 'correct EUMM version in prereqs');
    }

    subtest 'ExtUtils::MakeMaker->VERSION not asserted (outside of an eval) either' => sub {
        while ($Makefile_PL_content =~ /^(.*)ExtUtils::MakeMaker\s*->\s*VERSION\s*\(\s*([\d._]+)\s*\)/mg)
        {
            like($1, qr/eval/, 'VERSION assertion (on ' . $2 . ') done inside an eval');
        }
        pass 'no-op';
    };

    diag 'got log messages: ', explain $tzil->log_messages
        if not Test::Builder->new->is_passing;
}

done_testing;
