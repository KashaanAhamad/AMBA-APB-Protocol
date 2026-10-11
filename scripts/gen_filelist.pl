#!/usr/bin/perl
# ==============================================================================
# Script:  gen_filelist.pl
# Purpose: Generate file lists (.f files) for simulation and synthesis tools.
#
#          Scans the RTL and TB directories, resolves compile order based on
#          module dependency analysis, and outputs formatted file lists that
#          can be fed to vlog, vivado, or other EDA tools.
#
# Usage:
#   perl scripts/gen_filelist.pl                         # Generate all file lists
#   perl scripts/gen_filelist.pl --rtl-only              # RTL files only
#   perl scripts/gen_filelist.pl --tb-only               # TB files only
#   perl scripts/gen_filelist.pl --output sim/filelist.f # Custom output path
#   perl scripts/gen_filelist.pl --format vivado         # Vivado TCL format
#   perl scripts/gen_filelist.pl --help
#
# Output File Formats:
#   .f file (default) — One file per line, with +incdir+ directives
#   Vivado TCL        — read_verilog / read_systemverilog commands
#   Makefile           — Variable assignments for use in Makefiles
#
# Generated Files:
#   sim/rtl_filelist.f   — RTL files in compile order
#   sim/tb_filelist.f    — Testbench files in compile order
#   sim/all_filelist.f   — Combined RTL + TB file list
#
# Exit Codes:
#   0 — File lists generated successfully
#   1 — Missing files or dependency errors
#   2 — Invalid arguments
# ==============================================================================

use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use File::Spec;
use File::Find;
use Cwd 'abs_path';

# ==============================================================================
# Configuration
# ==============================================================================
my $rtl_only    = 0;
my $tb_only     = 0;
my $output      = '';
my $format      = 'f';      # 'f', 'vivado', 'makefile'
my $absolute    = 0;         # Use absolute paths
my $check       = 0;         # Verify all files exist
my $help        = 0;

GetOptions(
    'rtl-only'    => \$rtl_only,
    'tb-only'     => \$tb_only,
    'output=s'    => \$output,
    'format=s'    => \$format,
    'absolute'    => \$absolute,
    'check'       => \$check,
    'help|h'      => \$help,
) or die "Error in command line arguments. Use --help for usage.\n";

if ($help) {
    print_usage();
    exit 0;
}

# ==============================================================================
# Detect Project Root
# ==============================================================================
my $script_dir   = dirname(abs_path($0));
my $project_root = dirname($script_dir);
my $rtl_dir      = File::Spec->catdir($project_root, 'rtl');
my $tb_dir       = File::Spec->catdir($project_root, 'tb');
my $sim_dir      = File::Spec->catdir($project_root, 'sim');

# ==============================================================================
# RTL Files — Compile Order
# ==============================================================================
# Order matters! Dependencies must be compiled before dependents.
#
# Dependency tree:
#   apb_master_fsm.v  ← no dependencies (leaf)
#   apb_master.v      ← depends on apb_master_fsm
#   apb_decoder.v     ← no dependencies (leaf)
#   apb_mux.v         ← no dependencies (leaf)
#   apb_slave.v       ← no dependencies (leaf)
#   apb_top.v         ← depends on all above
# ==============================================================================
my @rtl_files = (
    { file => 'apb_master_fsm.v', desc => 'Master FSM — state machine for IDLE/SETUP/ACCESS' },
    { file => 'apb_master.v',     desc => 'Master — instantiates FSM, drives APB bus signals' },
    { file => 'apb_decoder.v',    desc => 'Decoder — address-to-PSELx mapping' },
    { file => 'apb_mux.v',       desc => 'Mux — routes selected slave response to master' },
    { file => 'apb_slave.v',     desc => 'Slave — register file with configurable wait states' },
    { file => 'apb_top.v',       desc => 'Top — integrates master, decoder, mux, 3 slaves' },
);

# ==============================================================================
# TB Files — Compile Order
# ==============================================================================
# Note: Class-based files (transaction, driver, etc.) are `included by
# apb_tb_top.sv, so only the interface, assertions, and top are compiled
# directly. The include files are listed separately for reference.
# ==============================================================================
my @tb_compile_files = (
    { file => 'apb_if.sv',         desc => 'Interface — signal bundle with clocking blocks' },
    { file => 'apb_assertions.sv', desc => 'SVA assertions — 12 protocol checks' },
    { file => 'apb_tb_top.sv',     desc => 'TB top — DUT instantiation, test selection' },
);

# Files that are `included (not compiled directly)
my @tb_include_files = (
    { file => 'apb_transaction.sv', desc => 'Transaction class — randomizable stimulus' },
    { file => 'apb_driver.sv',      desc => 'Driver — converts transactions to pin wiggling' },
    { file => 'apb_monitor.sv',     desc => 'Monitor — passive bus observer' },
    { file => 'apb_scoreboard.sv',  desc => 'Scoreboard — reference model + checker' },
    { file => 'apb_coverage.sv',    desc => 'Coverage — 6 functional covergroups' },
    { file => 'apb_env.sv',         desc => 'Environment — assembles all components' },
    { file => 'apb_test_lib.sv',    desc => 'Test library — 25 test cases' },
);

# ==============================================================================
# Verify Files Exist
# ==============================================================================
my $missing = 0;

if ($check || !$output) {
    # Check RTL files
    for my $entry (@rtl_files) {
        my $path = File::Spec->catfile($rtl_dir, $entry->{file});
        unless (-f $path) {
            warn "MISSING: $path\n";
            $missing++;
        }
    }

    # Check TB compile files
    for my $entry (@tb_compile_files) {
        my $path = File::Spec->catfile($tb_dir, $entry->{file});
        unless (-f $path) {
            warn "MISSING: $path\n";
            $missing++;
        }
    }

    # Check TB include files
    for my $entry (@tb_include_files) {
        my $path = File::Spec->catfile($tb_dir, $entry->{file});
        unless (-f $path) {
            warn "MISSING: $path\n";
            $missing++;
        }
    }

    if ($missing > 0) {
        warn "\nWARNING: $missing file(s) not found!\n\n";
        exit 1 if $check;
    }
    else {
        print "All source files verified.\n" if $check;
    }
}

# ==============================================================================
# Generate File Lists
# ==============================================================================
if ($output) {
    # Single output file
    my @files;
    push @files, @rtl_files        unless $tb_only;
    push @files, @tb_compile_files unless $rtl_only;

    my $rtl_inc = $rtl_only || (!$rtl_only && !$tb_only);
    my $tb_inc  = $tb_only  || (!$rtl_only && !$tb_only);

    write_filelist($output, \@files, $rtl_inc, $tb_inc);
}
else {
    # Generate standard file lists
    unless ($tb_only) {
        write_filelist(
            File::Spec->catfile($sim_dir, 'rtl_filelist.f'),
            \@rtl_files, 1, 0
        );
    }

    unless ($rtl_only) {
        write_filelist(
            File::Spec->catfile($sim_dir, 'tb_filelist.f'),
            \@tb_compile_files, 0, 1
        );
    }

    unless ($rtl_only || $tb_only) {
        my @all = (@rtl_files, @tb_compile_files);
        write_filelist(
            File::Spec->catfile($sim_dir, 'all_filelist.f'),
            \@all, 1, 1
        );
    }
}

print "\nFile list generation complete.\n\n";
exit 0;


# ==============================================================================
# Subroutine: write_filelist()
# ==============================================================================
sub write_filelist {
    my ($outfile, $files, $inc_rtl, $inc_tb) = @_;

    open(my $fh, '>', $outfile) or die "Cannot open $outfile for writing: $!\n";

    if ($format eq 'vivado') {
        write_vivado_format($fh, $files, $inc_rtl, $inc_tb);
    }
    elsif ($format eq 'makefile') {
        write_makefile_format($fh, $files, $inc_rtl, $inc_tb);
    }
    else {
        write_f_format($fh, $files, $inc_rtl, $inc_tb);
    }

    close $fh;
    print "Generated: $outfile\n";
}


# ==============================================================================
# Format: .f file (Simulator file list)
# ==============================================================================
sub write_f_format {
    my ($fh, $files, $inc_rtl, $inc_tb) = @_;

    print $fh "# ==============================================================================\n";
    print $fh "# AMBA APB Protocol — Source File List\n";
    print $fh "# Generated by gen_filelist.pl on " . localtime() . "\n";
    print $fh "# ==============================================================================\n\n";

    # Include directories
    if ($inc_rtl) {
        my $rtl_path = $absolute ? abs_path($rtl_dir) : make_relative($rtl_dir);
        print $fh "# Include directories\n";
        print $fh "+incdir+$rtl_path\n";
    }
    if ($inc_tb) {
        my $tb_path = $absolute ? abs_path($tb_dir) : make_relative($tb_dir);
        print $fh "+incdir+$tb_path\n";
    }
    print $fh "\n";

    # File list with descriptions
    my $current_section = '';
    for my $entry (@$files) {
        my $file = $entry->{file};
        my $desc = $entry->{desc};

        # Determine directory
        my $dir;
        if ($file =~ /\.sv$/ || grep { $_->{file} eq $file } @tb_compile_files) {
            $dir = $tb_dir;
        }
        else {
            $dir = $rtl_dir;
        }

        my $path = File::Spec->catfile($dir, $file);
        $path = abs_path($path) if $absolute;
        $path = make_relative($path) unless $absolute;

        # Section header
        my $section = ($dir eq $rtl_dir) ? 'RTL' : 'Testbench';
        if ($section ne $current_section) {
            print $fh "# ------ $section Sources ------\n";
            $current_section = $section;
        }

        print $fh "# $desc\n" if $desc;
        print $fh "$path\n";
    }

    # List included (non-compiled) TB files as comments
    if ($inc_tb && @tb_include_files) {
        print $fh "\n# ------ Included Files (not compiled directly) ------\n";
        print $fh "# These files are `included by apb_tb_top.sv:\n";
        for my $entry (@tb_include_files) {
            print $fh "#   $entry->{file}  — $entry->{desc}\n";
        }
    }

    print $fh "\n# End of file list\n";
}


# ==============================================================================
# Format: Vivado TCL
# ==============================================================================
sub write_vivado_format {
    my ($fh, $files, $inc_rtl, $inc_tb) = @_;

    print $fh "# ==============================================================================\n";
    print $fh "# AMBA APB Protocol — Vivado Source File List\n";
    print $fh "# Generated by gen_filelist.pl on " . localtime() . "\n";
    print $fh "# Source this file in your Vivado TCL script:\n";
    print $fh "#   source filelist.tcl\n";
    print $fh "# ==============================================================================\n\n";

    for my $entry (@$files) {
        my $file = $entry->{file};
        my $desc = $entry->{desc};

        my $dir = ($file =~ /\.sv$/) ? $tb_dir : $rtl_dir;
        my $path = File::Spec->catfile($dir, $file);
        $path = abs_path($path) if $absolute;

        my $cmd = ($file =~ /\.sv$/) ? 'read_verilog -sv' : 'read_verilog';

        print $fh "# $desc\n" if $desc;
        print $fh "$cmd $path\n";
    }

    print $fh "\n# End of Vivado file list\n";
}


# ==============================================================================
# Format: Makefile variables
# ==============================================================================
sub write_makefile_format {
    my ($fh, $files, $inc_rtl, $inc_tb) = @_;

    print $fh "# ==============================================================================\n";
    print $fh "# AMBA APB Protocol — Makefile Source Variables\n";
    print $fh "# Generated by gen_filelist.pl on " . localtime() . "\n";
    print $fh "# Include this in your Makefile: include filelist.mk\n";
    print $fh "# ==============================================================================\n\n";

    # Separate RTL and TB into different variables
    my @rtl_paths;
    my @tb_paths;

    for my $entry (@$files) {
        my $file = $entry->{file};
        my $dir = ($file =~ /\.sv$/) ? $tb_dir : $rtl_dir;
        my $path = File::Spec->catfile($dir, $file);
        $path = abs_path($path) if $absolute;
        $path = make_relative($path) unless $absolute;

        if ($dir eq $rtl_dir) {
            push @rtl_paths, $path;
        }
        else {
            push @tb_paths, $path;
        }
    }

    if (@rtl_paths) {
        print $fh "RTL_FILES := \\\n";
        for my $i (0 .. $#rtl_paths) {
            my $cont = ($i < $#rtl_paths) ? ' \\' : '';
            print $fh "    $rtl_paths[$i]$cont\n";
        }
        print $fh "\n";
    }

    if (@tb_paths) {
        print $fh "TB_FILES := \\\n";
        for my $i (0 .. $#tb_paths) {
            my $cont = ($i < $#tb_paths) ? ' \\' : '';
            print $fh "    $tb_paths[$i]$cont\n";
        }
        print $fh "\n";
    }

    print $fh "ALL_FILES := \$(RTL_FILES) \$(TB_FILES)\n";
}


# ==============================================================================
# Helper: make_relative()
# ==============================================================================
sub make_relative {
    my ($path) = @_;
    # Make path relative to sim directory
    my $rel = File::Spec->abs2rel($path, $sim_dir);
    return $rel;
}


# ==============================================================================
# Usage
# ==============================================================================
sub print_usage {
    print <<'EOF';

Usage: gen_filelist.pl [OPTIONS]

Generate file lists (.f files) for simulation and synthesis tools.

Options:
  --rtl-only          Generate RTL file list only
  --tb-only           Generate TB file list only
  --output <path>     Write to a single output file
  --format <type>     Output format: f (default), vivado, makefile
  --absolute          Use absolute file paths
  --check             Verify all source files exist
  --help              Show this help message

Output Formats:
  f          Standard .f file (vlog -f filelist.f)
  vivado     Vivado TCL commands (read_verilog ...)
  makefile   Makefile variable assignments (RTL_FILES := ...)

Examples:
  perl gen_filelist.pl                              # Generate all .f files
  perl gen_filelist.pl --rtl-only                   # RTL only
  perl gen_filelist.pl --output sim/all.f --absolute
  perl gen_filelist.pl --format vivado --output synth/sources.tcl
  perl gen_filelist.pl --format makefile --output sim/filelist.mk
  perl gen_filelist.pl --check                      # Verify files exist

EOF
}
