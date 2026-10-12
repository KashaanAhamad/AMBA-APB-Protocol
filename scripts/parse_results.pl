#!/usr/bin/perl
# ==============================================================================
# Script:  parse_results.pl
# Purpose: Parse QuestaSim simulation log files and extract structured results.
#
#          Reads simulation log files (from run_sim.sh or run_regression.sh),
#          extracts key metrics, and outputs a formatted summary. Supports
#          parsing single logs or batching all logs in a results directory.
#
# Usage:
#   perl scripts/parse_results.pl results/test_single_write.log
#   perl scripts/parse_results.pl --dir results/
#   perl scripts/parse_results.pl --dir results/ --csv results/summary.csv
#   perl scripts/parse_results.pl --dir results/ --format markdown
#   perl scripts/parse_results.pl --help
#
# Extracted Metrics:
#   - Test name
#   - PASS / FAIL verdict
#   - Transfer count (total, writes, reads)
#   - Scoreboard results (passed, failed checks)
#   - Assertion results (passes, failures)
#   - Coverage percentages (per covergroup)
#   - Wait cycle statistics
#   - Simulation time
#   - Error/warning messages
#
# Exit Codes:
#   0 — All parsed tests passed
#   1 — One or more tests failed
#   2 — Parse error or invalid arguments
# ==============================================================================

use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use File::Glob ':bsd_glob';

# ==============================================================================
# Configuration
# ==============================================================================
my $dir         = '';
my $csv_output  = '';
my $format      = 'table';    # 'table', 'csv', 'markdown', 'json'
my $verbose     = 0;
my $help        = 0;

GetOptions(
    'dir=s'    => \$dir,
    'csv=s'    => \$csv_output,
    'format=s' => \$format,
    'verbose'  => \$verbose,
    'help|h'   => \$help,
) or die "Error in command line arguments. Use --help for usage.\n";

if ($help) {
    print_usage();
    exit 0;
}

# ==============================================================================
# Collect log files
# ==============================================================================
my @log_files;

if ($dir) {
    @log_files = bsd_glob("$dir/*.log");
    die "ERROR: No .log files found in '$dir'\n" unless @log_files;
    # Sort alphabetically
    @log_files = sort @log_files;
}
elsif (@ARGV) {
    @log_files = @ARGV;
    for my $f (@log_files) {
        die "ERROR: File not found: $f\n" unless -f $f;
    }
}
else {
    print "ERROR: No log file(s) specified.\n\n";
    print_usage();
    exit 2;
}

# ==============================================================================
# Parse each log file
# ==============================================================================
my @results;

for my $log_file (@log_files) {
    my $result = parse_log($log_file);
    push @results, $result;

    if ($verbose) {
        print_verbose_result($result);
    }
}

# ==============================================================================
# Output results
# ==============================================================================
if ($format eq 'csv' || $csv_output) {
    output_csv(\@results, $csv_output);
}

if ($format eq 'markdown') {
    output_markdown(\@results);
}
elsif ($format eq 'json') {
    output_json(\@results);
}
else {
    output_table(\@results);
}

# ==============================================================================
# Exit code based on results
# ==============================================================================
my $any_failed = grep { $_->{verdict} eq 'FAIL' } @results;
exit($any_failed ? 1 : 0);


# ==============================================================================
# Subroutine: parse_log()
# ==============================================================================
# Parses a single simulation log file and returns a hash reference with
# all extracted metrics.
# ==============================================================================
sub parse_log {
    my ($file) = @_;

    my %r = (
        file             => $file,
        test_name        => basename($file, '.log'),
        verdict          => 'UNKNOWN',

        # Driver stats
        total_transfers  => 0,
        num_writes       => 0,
        num_reads        => 0,
        num_errors_drv   => 0,
        num_timeouts     => 0,

        # Monitor stats
        mon_transfers    => 0,
        mon_b2b          => 0,
        total_wait_cyc   => 0,
        max_wait         => 0,

        # Scoreboard stats
        scb_checked      => 0,
        scb_passed       => 0,
        scb_failed       => 0,
        scb_write_upd    => 0,
        scb_read_cmp     => 0,

        # Assertion stats
        assert_passes    => 0,
        assert_fails     => 0,

        # Coverage
        cg1_pct          => '',
        cg2_pct          => '',
        cg3_pct          => '',
        cg4_pct          => '',
        cg5_pct          => '',
        cg6_pct          => '',
        overall_cov      => '',

        # Errors and warnings collected
        error_msgs       => [],
        warning_msgs     => [],

        # Timing
        sim_time         => '',
    );

    open(my $fh, '<', $file) or do {
        warn "WARNING: Cannot open $file: $!\n";
        $r{verdict} = 'ERROR';
        return \%r;
    };

    while (my $line = <$fh>) {
        chomp $line;

        # -----------------------------------------------------------------
        # Driver Statistics
        # -----------------------------------------------------------------
        if ($line =~ /Total Transfers\s*:\s*(\d+)/) {
            $r{total_transfers} = $1 unless $r{total_transfers};
        }
        if ($line =~ /Writes\s*:\s*(\d+)/) {
            $r{num_writes} = $1 unless $r{num_writes};
        }
        if ($line =~ /Reads\s*:\s*(\d+)/) {
            $r{num_reads} = $1 unless $r{num_reads};
        }
        if ($line =~ /Errors\s*:\s*(\d+)/ && $line !~ /PSLVERR|Assertion/) {
            $r{num_errors_drv} = $1 unless $r{num_errors_drv};
        }
        if ($line =~ /Timeouts\s*:\s*(\d+)/) {
            $r{num_timeouts} = $1;
        }

        # -----------------------------------------------------------------
        # Monitor Statistics
        # -----------------------------------------------------------------
        if ($line =~ /Monitor Statistics/) {
            # Next few lines contain monitor stats
            # (handled by subsequent matches below)
        }
        if ($line =~ /Back-to-Back\s*:\s*(\d+)/) {
            $r{mon_b2b} = $1;
        }
        if ($line =~ /Total Wait Cycles\s*:\s*(\d+)/) {
            $r{total_wait_cyc} = $1;
        }
        if ($line =~ /Max Wait.*:\s*(\d+)/) {
            $r{max_wait} = $1;
        }

        # -----------------------------------------------------------------
        # Scoreboard Results
        # -----------------------------------------------------------------
        if ($line =~ /Total Checked\s*:\s*(\d+)/) {
            $r{scb_checked} = $1;
        }
        if ($line =~ /PASSED\s*:\s*(\d+)/) {
            $r{scb_passed} = $1;
        }
        if ($line =~ /FAILED\s*:\s*(\d+)/) {
            $r{scb_failed} = $1;
        }
        if ($line =~ /Write Updates\s*:\s*(\d+)/) {
            $r{scb_write_upd} = $1;
        }
        if ($line =~ /Read Compares\s*:\s*(\d+)/) {
            $r{scb_read_cmp} = $1;
        }

        # -----------------------------------------------------------------
        # Assertion Results
        # -----------------------------------------------------------------
        if ($line =~ /Assertion Passes\s*:\s*(\d+)/) {
            $r{assert_passes} = $1;
        }
        if ($line =~ /Assertion Fails\s*:\s*(\d+)/) {
            $r{assert_fails} = $1;
        }

        # -----------------------------------------------------------------
        # Coverage Percentages
        # -----------------------------------------------------------------
        if ($line =~ /CG1 Transfer Type\s*:\s*([\d.]+)/) {
            $r{cg1_pct} = $1;
        }
        if ($line =~ /CG2 Address Space\s*:\s*([\d.]+)/) {
            $r{cg2_pct} = $1;
        }
        if ($line =~ /CG3 Protocol State\s*:\s*([\d.]+)/) {
            $r{cg3_pct} = $1;
        }
        if ($line =~ /CG4 Error Response\s*:\s*([\d.]+)/) {
            $r{cg4_pct} = $1;
        }
        if ($line =~ /CG5 Sequences\s*:\s*([\d.]+)/) {
            $r{cg5_pct} = $1;
        }
        if ($line =~ /CG6 Data Patterns\s*:\s*([\d.]+)/) {
            $r{cg6_pct} = $1;
        }
        if ($line =~ /OVERALL AVERAGE\s*:\s*([\d.]+)/) {
            $r{overall_cov} = $1;
        }

        # -----------------------------------------------------------------
        # Verdict
        # -----------------------------------------------------------------
        if ($line =~ /ALL CHECKS PASSED/) {
            $r{verdict} = 'PASS' unless $r{verdict} eq 'FAIL';
        }
        if ($line =~ /SIMULATION PASSED/) {
            $r{verdict} = 'PASS' unless $r{verdict} eq 'FAIL';
        }
        if ($line =~ /SIMULATION FAILED/) {
            $r{verdict} = 'FAIL';
        }
        if ($line =~ /CHECK\(S\) FAILED/) {
            $r{verdict} = 'FAIL';
        }
        if ($line =~ /SIMULATION TIMEOUT/) {
            $r{verdict} = 'TIMEOUT';
        }

        # -----------------------------------------------------------------
        # Collect error and warning messages
        # -----------------------------------------------------------------
        if ($line =~ /\*\*\* FAIL \*\*\*|SCB.*FAIL|APB_A\d+.*FAIL/) {
            push @{$r{error_msgs}}, $line;
        }
        if ($line =~ /WARNING|STABILITY VIOLATION/) {
            push @{$r{warning_msgs}}, $line;
        }

        # -----------------------------------------------------------------
        # Simulation time
        # -----------------------------------------------------------------
        if ($line =~ /Simulation finished.*?(\d+)/) {
            $r{sim_time} = $1;
        }
    }

    close $fh;

    # Final verdict logic
    if ($r{verdict} eq 'UNKNOWN') {
        if ($r{scb_failed} == 0 && $r{assert_fails} == 0 && $r{scb_checked} > 0) {
            $r{verdict} = 'PASS';
        }
        elsif ($r{scb_failed} > 0 || $r{assert_fails} > 0) {
            $r{verdict} = 'FAIL';
        }
    }

    return \%r;
}


# ==============================================================================
# Output: Table Format (Terminal)
# ==============================================================================
sub output_table {
    my ($results) = @_;

    my $total  = scalar @$results;
    my $passed = grep { $_->{verdict} eq 'PASS' } @$results;
    my $failed = grep { $_->{verdict} ne 'PASS' } @$results;

    print "\n";
    print "=" x 78, "\n";
    print "  AMBA APB — Simulation Results Summary\n";
    print "  Parsed: $total log file(s)\n";
    print "=" x 78, "\n\n";

    # Header
    printf "  %-38s │ %-7s │ %6s │ %6s │ %6s\n",
           "Test Name", "Verdict", "Xfers", "SCB_OK", "SVA_OK";
    print "  ", "-" x 38, "─┼─", "-" x 7, "─┼─", "-" x 6, "─┼─",
          "-" x 6, "─┼─", "-" x 6, "\n";

    for my $r (@$results) {
        my $verdict_str = $r->{verdict};
        printf "  %-38s │ %-7s │ %6d │ %6d │ %6d\n",
               $r->{test_name},
               $verdict_str,
               $r->{total_transfers},
               $r->{scb_passed},
               $r->{assert_passes};
    }

    # Footer
    print "\n";
    print "  ", "-" x 78, "\n";
    printf "  Total: %-4d  |  Passed: %-4d  |  Failed: %-4d\n",
           $total, $passed, $failed;
    print "  ", "-" x 78, "\n";

    if ($failed == 0) {
        print "\n  *** ALL TESTS PASSED ***\n\n";
    }
    else {
        print "\n  *** $failed TEST(S) FAILED ***\n";
        print "  Failed tests:\n";
        for my $r (@$results) {
            if ($r->{verdict} ne 'PASS') {
                print "    - $r->{test_name} ($r->{verdict})\n";
            }
        }
        print "\n";
    }
}


# ==============================================================================
# Output: CSV Format
# ==============================================================================
sub output_csv {
    my ($results, $outfile) = @_;

    my $fh;
    if ($outfile) {
        open($fh, '>', $outfile) or die "Cannot open $outfile for writing: $!\n";
    }
    else {
        $fh = \*STDOUT;
    }

    # Header
    print $fh join(',', qw(
        test_name verdict total_transfers num_writes num_reads
        scb_checked scb_passed scb_failed
        assert_passes assert_fails
        cg1_pct cg2_pct cg3_pct cg4_pct cg5_pct cg6_pct overall_cov
        num_timeouts mon_b2b max_wait
    )), "\n";

    # Data rows
    for my $r (@$results) {
        print $fh join(',',
            $r->{test_name},
            $r->{verdict},
            $r->{total_transfers},
            $r->{num_writes},
            $r->{num_reads},
            $r->{scb_checked},
            $r->{scb_passed},
            $r->{scb_failed},
            $r->{assert_passes},
            $r->{assert_fails},
            $r->{cg1_pct} || 'N/A',
            $r->{cg2_pct} || 'N/A',
            $r->{cg3_pct} || 'N/A',
            $r->{cg4_pct} || 'N/A',
            $r->{cg5_pct} || 'N/A',
            $r->{cg6_pct} || 'N/A',
            $r->{overall_cov} || 'N/A',
            $r->{num_timeouts},
            $r->{mon_b2b},
            $r->{max_wait},
        ), "\n";
    }

    if ($outfile) {
        close $fh;
        print "CSV report saved to: $outfile\n";
    }
}


# ==============================================================================
# Output: Markdown Format
# ==============================================================================
sub output_markdown {
    my ($results) = @_;

    my $total  = scalar @$results;
    my $passed = grep { $_->{verdict} eq 'PASS' } @$results;
    my $failed = $total - $passed;

    print "# AMBA APB — Simulation Results\n\n";
    print "**Date:** " . localtime() . "  \n";
    print "**Total:** $total | **Passed:** $passed | **Failed:** $failed\n\n";

    # Main results table
    print "| Test Name | Verdict | Transfers | SCB Pass | SCB Fail | SVA Pass | SVA Fail |\n";
    print "|:----------|:--------|----------:|---------:|---------:|---------:|---------:|\n";

    for my $r (@$results) {
        printf "| %-37s | %-7s | %9d | %8d | %8d | %8d | %8d |\n",
               $r->{test_name},
               $r->{verdict},
               $r->{total_transfers},
               $r->{scb_passed},
               $r->{scb_failed},
               $r->{assert_passes},
               $r->{assert_fails};
    }

    # Coverage table (if any test has coverage data)
    my $has_cov = grep { $_->{overall_cov} } @$results;
    if ($has_cov) {
        print "\n## Coverage Summary\n\n";
        print "| Test Name | CG1 | CG2 | CG3 | CG4 | CG5 | CG6 | Overall |\n";
        print "|:----------|----:|----:|----:|----:|----:|----:|--------:|\n";

        for my $r (@$results) {
            next unless $r->{overall_cov};
            printf "| %-37s | %s | %s | %s | %s | %s | %s | %s |\n",
                   $r->{test_name},
                   $r->{cg1_pct} || '-',
                   $r->{cg2_pct} || '-',
                   $r->{cg3_pct} || '-',
                   $r->{cg4_pct} || '-',
                   $r->{cg5_pct} || '-',
                   $r->{cg6_pct} || '-',
                   $r->{overall_cov} || '-';
        }
    }

    # Failed test details
    if ($failed > 0) {
        print "\n## Failed Tests\n\n";
        for my $r (@$results) {
            next if $r->{verdict} eq 'PASS';
            print "### $r->{test_name} ($r->{verdict})\n\n";
            if (@{$r->{error_msgs}}) {
                print "```\n";
                for my $msg (@{$r->{error_msgs}}[0..min(9, $#{$r->{error_msgs}})]) {
                    print "$msg\n";
                }
                print "```\n\n";
            }
        }
    }

    print "\n";
}


# ==============================================================================
# Output: JSON Format
# ==============================================================================
sub output_json {
    my ($results) = @_;

    print "[\n";
    for my $i (0 .. $#$results) {
        my $r = $results->[$i];
        print "  {\n";
        print "    \"test_name\": \"$r->{test_name}\",\n";
        print "    \"verdict\": \"$r->{verdict}\",\n";
        print "    \"transfers\": {\n";
        print "      \"total\": $r->{total_transfers},\n";
        print "      \"writes\": $r->{num_writes},\n";
        print "      \"reads\": $r->{num_reads}\n";
        print "    },\n";
        print "    \"scoreboard\": {\n";
        print "      \"checked\": $r->{scb_checked},\n";
        print "      \"passed\": $r->{scb_passed},\n";
        print "      \"failed\": $r->{scb_failed}\n";
        print "    },\n";
        print "    \"assertions\": {\n";
        print "      \"passes\": $r->{assert_passes},\n";
        print "      \"fails\": $r->{assert_fails}\n";
        print "    },\n";
        print "    \"coverage\": {\n";
        printf "      \"cg1\": %s,\n", $r->{cg1_pct} || 'null';
        printf "      \"cg2\": %s,\n", $r->{cg2_pct} || 'null';
        printf "      \"cg3\": %s,\n", $r->{cg3_pct} || 'null';
        printf "      \"cg4\": %s,\n", $r->{cg4_pct} || 'null';
        printf "      \"cg5\": %s,\n", $r->{cg5_pct} || 'null';
        printf "      \"cg6\": %s,\n", $r->{cg6_pct} || 'null';
        printf "      \"overall\": %s\n", $r->{overall_cov} || 'null';
        print "    },\n";
        print "    \"timeouts\": $r->{num_timeouts},\n";
        print "    \"back_to_back\": $r->{mon_b2b},\n";
        print "    \"max_wait_cycles\": $r->{max_wait}\n";
        print "  }";
        print "," if $i < $#$results;
        print "\n";
    }
    print "]\n";
}


# ==============================================================================
# Verbose Output (per test)
# ==============================================================================
sub print_verbose_result {
    my ($r) = @_;

    print "\n", "=" x 60, "\n";
    print "  Test: $r->{test_name}\n";
    print "  File: $r->{file}\n";
    print "  Verdict: $r->{verdict}\n";
    print "=" x 60, "\n";
    print "  Driver:     $r->{total_transfers} transfers ";
    print "($r->{num_writes} W, $r->{num_reads} R, $r->{num_timeouts} timeouts)\n";
    print "  Scoreboard: $r->{scb_checked} checked, ";
    print "$r->{scb_passed} passed, $r->{scb_failed} failed\n";
    print "  Assertions: $r->{assert_passes} passed, $r->{assert_fails} failed\n";
    print "  Wait Stats: total=$r->{total_wait_cyc}, max=$r->{max_wait}, ";
    print "b2b=$r->{mon_b2b}\n";

    if ($r->{overall_cov}) {
        print "  Coverage:   CG1=$r->{cg1_pct}% CG2=$r->{cg2_pct}% CG3=$r->{cg3_pct}%\n";
        print "              CG4=$r->{cg4_pct}% CG5=$r->{cg5_pct}% CG6=$r->{cg6_pct}%\n";
        print "              Overall=$r->{overall_cov}%\n";
    }

    if (@{$r->{error_msgs}}) {
        print "  Errors:\n";
        for my $msg (@{$r->{error_msgs}}[0..min(4, $#{$r->{error_msgs}})]) {
            print "    $msg\n";
        }
    }

    print "\n";
}


# ==============================================================================
# Helper: min()
# ==============================================================================
sub min {
    my ($a, $b) = @_;
    return ($a < $b) ? $a : $b;
}


# ==============================================================================
# Usage
# ==============================================================================
sub print_usage {
    print <<'EOF';

Usage: parse_results.pl [OPTIONS] [LOG_FILE ...]

Parse QuestaSim simulation logs and extract structured results.

Options:
  --dir <path>        Parse all .log files in a directory
  --csv <path>        Write results as CSV to a file
  --format <type>     Output format: table, csv, markdown, json (default: table)
  --verbose           Print detailed per-test breakdown
  --help              Show this help message

Examples:
  perl parse_results.pl results/test_single_write.log
  perl parse_results.pl --dir results/
  perl parse_results.pl --dir results/ --csv summary.csv
  perl parse_results.pl --dir results/ --format markdown > report.md
  perl parse_results.pl --dir results/ --format json > results.json
  perl parse_results.pl --dir results/ --verbose

EOF
}
