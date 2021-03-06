# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#-------------------------------------------------------

=head1
    xCAT plugin package to handle rinstall and winstall

    Supported command:
        rinstall - runs nodeset, rsetboot, rpower commands
        winstall - also opens the console

=cut

#-------------------------------------------------------
package xCAT_plugin::rinstall;
use strict;

require xCAT::Utils;
require xCAT::MsgUtils;
use xCAT::NodeRange;
use xCAT::Table;

use Data::Dumper;
use Getopt::Long;

#-------------------------------------------------------

=head3  handled_commands

    Return list of commands handled by this plugin

=cut

#-------------------------------------------------------
sub handled_commands {
    return {
        rinstall => "rinstall",
        winstall => "rinstall",
    };
}

#-------------------------------------------------------

=head3  Process the command

=cut

#-------------------------------------------------------
sub process_request {
    my $request  = shift;
    my $callback = shift;
    my $subreq   = shift;

    rinstall($request, $callback, $subreq);
}

#-------------------------------------------------------

=head3  rinstall

    Wrapper around nodeset, rsetboot, rpower for the admin convenience

=cut

#-------------------------------------------------------
sub rinstall {
    my ($req, $callback, $subreq) = @_;
    $::CALLBACK = $callback;
    my $CONSOLE;
    my $OSIMAGE;
    my $STATES;
    my $ignorekernelchk;
    my $VERBOSE;
    my $HELP;
    my $VERSION;
    my $UEFIMODE;

    # Could be rinstall or winstall
    my $command = $req->{command}->[0];

    my $nodes;
    my @nodes;
    my %nodes;

    # There are nodes
    if (defined($req->{node})) {
        $nodes = $req->{node};
        @nodes = @$nodes;
    }

    my $args;

    # There are arguments
    if (defined($req->{arg})) {
        $args = $req->{arg};
        @ARGV = @{$args};
    }

    if (($command =~ /rinstall/) or ($command =~ /winstall/)) {
        my $state = $ARGV[0];
        my $reststates;
        ($state, $reststates) = split(/,/, $state, 2);
        chomp($state);
        if ($state eq "image" or $state eq "winshell" or $state =~ /^osimage/) {
            my $target;
            my $action;
            if ($state =~ /=/) {
                ($state, $target) = split '=', $state, 2;
                if ($target =~ /:/) {
                    ($target, $action) = split ':', $target, 2;
                }
            }
            else {
                if ($state =~ /:/) {
                    ($state, $action) = split ':', $state, 2;
                }
            }
            if ($state eq 'osimage') {
                $OSIMAGE = $target;
            }
        }
        else {
            unless ($state =~ /-/) {
                $STATES = $state;
            }
        }

        Getopt::Long::Configure("bundling");
        Getopt::Long::Configure("no_pass_through");
        unless (
            GetOptions('O|osimage=s' => \$OSIMAGE,
                'ignorekernelchk' => \$ignorekernelchk,
                'V|verbose'       => \$VERBOSE,
                'h|help'          => \$HELP,
                'v|version'       => \$VERSION,
                'u|uefimode'      => \$UEFIMODE,
                'c|console'       => \$CONSOLE)
          ) {
            &usage($command, $callback);
            return 1;
        }
    }
    if ($HELP) {
        &usage($command, $callback);
        return 0;
    }
    if ($VERSION) {
        my $version = xCAT::Utils->Version();
        my $rsp     = {};
        $rsp->{data}->[0] = "$version";
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return 0;
    }
    if (scalar(@nodes) == 0) {
        &usage($command, $callback);
        return 1;
    }

    my $rc = 0;
    my @parameter;

    my $nodehmtable = xCAT::Table->new("nodehm");
    my $nodehmcache = $nodehmtable->getNodesAttribs(\@nodes, ['mgt']);
    $nodehmtable->close();

    if ($OSIMAGE) {

        # if -O|--osimage or osimage=<imagename> is specified,
        # call "nodeset ... osimage= ..." to set the boot state of the noderange to the specified osimage,
        # "nodeset" will handle the updating of node attributes such as os,arch,profile,provmethod.

        my $noderestable = xCAT::Table->new("noderes");
        my $noderescache = $noderestable->getNodesAttribs(\@nodes, ['netboot']);
        $noderestable->close();
        my $nodetypetable = xCAT::Table->new("nodetype");
        my $nodetypecache = $nodetypetable->getNodesAttribs(\@nodes, ['arch']);
        $nodetypetable->close();
        my $osimagetable = xCAT::Table->new("osimage");
        (my $ref) = $osimagetable->getAttribs({ imagename => $OSIMAGE }, 'osvers', 'osarch', 'imagetype');
        $osimagetable->close();

        unless (defined($ref->{osarch})) {
            my $rsp = {};
            $rsp->{error}->[0] = "$OSIMAGE 'osarch' attribute not defined in 'osimage' table.";
            $rsp->{errorcode}->[0] = 1;
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
        my $osimagearch = $ref->{osarch};
        my $netbootval = xCAT::Utils->lookupNetboot($ref->{osvers}, $ref->{osarch}, $ref->{imagetype});
        my @validnodes;
        foreach my $node (@nodes) {
            unless ($noderescache)  { next; }
            unless ($nodetypecache) { next; }
            unless ($nodehmcache)   { next; }
            my $noderesattribs  = $noderescache->{$node}->[0];
            my $nodetypeattribs = $nodetypecache->{$node}->[0];
            my $nodehmattribs   = $nodehmcache->{$node}->[0];
            unless (defined($noderesattribs) and defined($noderesattribs->{'netboot'})) {
                my $rsp = {};
                $rsp->{error}->[0] = "$node: Missing the 'netboot' attribute.";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }
            else {
                unless ($netbootval =~ /$noderesattribs->{'netboot'}/i) {
                    $callback->({ warning => [ $node . ": $noderesattribs->{'netboot'} might be invalid when provisioning $OSIMAGE,valid options: \"$netbootval\". For more details see the 'netboot' description in the output of \"tabdump -d noderes\"." ] });
                    next;
                }
            }

            unless (defined($nodetypeattribs) and defined($nodetypeattribs->{'arch'})) {
                my $rsp = {};
                $rsp->{error}->[0] = "$node: 'arch' attribute not defined in 'nodetype' table.";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }
            my $nodetypearch = $nodetypeattribs->{'arch'};
            if ($nodetypearch ne $osimagearch) {
                unless ((($nodetypearch =~ /ppc64le/) or ($nodetypearch =~ /ppc64el/)) and (($osimagearch =~ /ppc64le/) or ($osimagearch =~ /ppc64el/))) {
                    my $rsp = {};
                    $rsp->{error}->[0] = "$node: The value of 'arch' attribute is not same as the 'osarch' attribute for osimage.";
                    $rsp->{errorcode}->[0] = 1;
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    next;
                }
            }

            unless (defined($nodehmattribs) and defined($nodehmattribs->{'mgt'})) {
                my $rsp = {};
                $rsp->{error}->[0] = "$node: 'mgt' attribute not defined in 'nodehm' table.";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }
            push @validnodes, $node;
        }

        #only provision the normal nodes
        @nodes = @validnodes;

        push @parameter, "osimage=$OSIMAGE";
        if ($ignorekernelchk) {
            push @parameter, " --ignorekernelchk";
        }
    }
    elsif ($STATES) {
        push @parameter, "$STATES";
    }
    else {

        # No osimage specified, set the boot state of each node based on the nodetype.provmethod:
        # 1) if nodetype.provmethod = [install/netboot/statelite],
        #  then output error message.
        # 2) if nodetype.provmethod = <osimage>,
        #  then call "nodeset ... osimage"

        # Group the nodes according to the nodetype.provmethod
        my %tphash;
        my $nodetypetable = xCAT::Table->new("nodetype");
        my $nodetypecache = $nodetypetable->getNodesAttribs(\@nodes, ['provmethod']);
        $nodetypetable->close();
        foreach my $node (@nodes) {
            unless ($nodetypecache) { next; }
            my $nodetypeattribs = $nodetypecache->{$node}->[0];
            unless (defined($nodetypeattribs) and defined($nodetypeattribs->{'provmethod'})) {
                my $rsp = {};
                $rsp->{error}->[0] = "$node: 'provmethod' attribute not defined in 'nodetype' table.";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }
            else {
                push(@{ $tphash{ $nodetypeattribs->{'provmethod'} } }, $node);
            }
        }

        # Now for each group based on provmethod
        my @validnodes;
        foreach my $key (keys %tphash) {
            $::RUNCMD_RC = 0;
            my @pnnodes = @{ $tphash{$key} };

            # If nodetype.provmethod = [install|netboot|statelite]
            if ($key =~ /^(install|netboot|statelite)$/) {
                my $rsp = {};
                $rsp->{error}->[0] = "@pnnodes: The options 'install', 'netboot', and 'statelite' have been deprecated, use 'nodeset <noderange> osimage=<imagename>' instead.";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }

            # If nodetype.provmethod != [install|netboot|statelite]
            else {
                push @validnodes, @pnnodes;
            }
        }

        #only provision the normal nodes
        @nodes = @validnodes;

        push @parameter, "osimage";
    }

    if (scalar(@nodes) == 0) {
        my $rsp = {};
        $rsp->{error}->[0]     = "No available nodes for provision.";
        $rsp->{errorcode}->[0] = 1;
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }
    else {
        my $rsp = {};
        $rsp->{data}->[0] = "Provision node(s): @nodes";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }
    %nodes = map { $_, 1 } @nodes;

    # Run nodeset $noderange $parameter
    my $res =
      xCAT::Utils->runxcmd(
        {
            command => ["nodeset"],
            node    => \@nodes,
            arg     => \@parameter
        },
        $subreq, -1, 1);

    $rc = $::RUNCMD_RC;
    my $rsp = {};
    if ($VERBOSE) {
        my @cmd = "Run command: nodeset @nodes @parameter";
        push @{ $rsp->{data} }, @cmd;
        push @{ $rsp->{data} }, @$res;
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }
    unless ($rc == 0) {

        # We got an error with the nodeset
        my @successnodes;
        my @failurenodes;
        foreach my $line (@$res) {
            $rsp->{data}->[0] = $line;
            if (($line =~ /: install/) or ($line =~ /: netboot/)) {
                my $successnode;
                my $restline;
                ($successnode, $restline) = split(/:/, $line, 2);
                $nodes{$successnode} = 0;
                push @successnodes, $successnode;
            }
            if ($line =~ /dhcp server is not running/) {
                my $rsp = {};
                $rsp->{error}->[0]     = "Fatal error: dhcp server is not running";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }
            xCAT::MsgUtils->message("I", $rsp, $callback);
        }
        foreach my $node (@nodes) {
            if ($nodes{$node} == 1) {
                push @failurenodes, $node;
            }
        }
        my $rsp = {};
        $rsp->{error}->[0] = "failed to run 'nodeset' against the following nodes: @failurenodes";
        $rsp->{errorcode}->[0] = 1;
        xCAT::MsgUtils->message("E", $rsp, $callback);
        @nodes = @successnodes;
    }

    # Group the nodes according to the nodehm.mgt
    my %hmhash;
    foreach my $node (@nodes) {
        unless ($nodehmcache) { next; }
        my $nodehmattribs = $nodehmcache->{$node}->[0];
        push(@{ $hmhash{ $nodehmattribs->{'mgt'} } }, $node);
    }

    # Now for each group based on mgt
    foreach my $hmkey (keys %hmhash) {
        $::RUNCMD_RC = 0;
        my @nodes = @{ $hmhash{$hmkey} };
        unless (($hmkey =~ /^ipmi$/) or ($hmkey =~ /^blade$/) or ($hmkey =~ /^hmc$/) or ($hmkey =~ /^ivm$/) or ($hmkey =~ /^fsp$/) or ($hmkey =~ /^kvm$/) or ($hmkey =~ /^esx$/) or ($hmkey =~ /^rhevm$/)) {
            my $rsp = {};
            $rsp->{error}->[0] = "@nodes: rinstall only support nodehm.mgt type 'ipmi', 'blade', 'hmc', 'ivm', 'fsp', 'kvm', 'esx', 'rhevm'.";
            $rsp->{errorcode}->[0] = 1;
            xCAT::MsgUtils->message("E", $rsp, $callback);
            next;
        }
        if (($hmkey =~ /^ivm$/) or ($hmkey =~ /^fsp$/) or ($hmkey =~ /^hmc$/)) {
            %nodes = map { $_, 1 } @nodes;

            # Run rnetboot $noderange
            my $res =
              xCAT::Utils->runxcmd(
                {
                    command => ["rnetboot"],
                    node    => \@nodes
                },
                $subreq, -1, 1);

            $rc = $::RUNCMD_RC;
            my $rsp = {};
            if ($VERBOSE) {
                my @cmd = "Run command: rnetboot @nodes";
                push @{ $rsp->{data} }, @cmd;
                push @{ $rsp->{data} }, @$res;
                xCAT::MsgUtils->message("I", $rsp, $callback);
            }
            unless ($rc == 0) {

                # We got an error with the rnetboot
                my @failurenodes;
                foreach my $line (@$res) {
                    $rsp->{data}->[0] = $line;
                    if ($line =~ /: Success/) {
                        my $successnode;
                        my $restline;
                        ($successnode, $restline) = split(/:/, $line, 2);
                        $nodes{$successnode} = 0;
                    }
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
                foreach my $node (@nodes) {
                    if ($nodes{$node} == 1) {
                        push @failurenodes, $node;
                    }
                }
                my $rsp = {};
                $rsp->{error}->[0] = "failed to run 'rnetboot' against the following nodes: @failurenodes";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
            }
        }
        else {
            # Call "rsetboot" to set the boot order of the nodehm.mgt=ipmi nodes
            if ($hmkey =~ /^ipmi$/) {
                %nodes = map { $_, 1 } @nodes;

                # Run rsetboot $noderange net
                my @rsetbootarg;
                push @rsetbootarg, "net";
                if ($UEFIMODE) {
                    push @rsetbootarg, "-u";
                }
                my $res =
                  xCAT::Utils->runxcmd(
                    {
                        command => ["rsetboot"],
                        node    => \@nodes,
                        arg     => \@rsetbootarg
                    },
                    $subreq, -1, 1);

                $rc = $::RUNCMD_RC;
                my $rsp = {};
                if ($VERBOSE) {
                    my @cmd = "Run command: rsetboot @nodes @rsetbootarg";
                    push @{ $rsp->{data} }, @cmd;
                    push @{ $rsp->{data} }, @$res;
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
                unless ($rc == 0) {

                    # We got an error with the rsetboot
                    my @successnodes;
                    my @failurenodes;
                    foreach my $line (@$res) {
                        $rsp->{data}->[0] = $line;
                        if ($line =~ /: Network/) {
                            my $successnode;
                            my $restline;
                            ($successnode, $restline) = split(/:/, $line, 2);
                            $nodes{$successnode} = 0;
                            push @successnodes, $successnode;
                        }
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                    foreach my $node (@nodes) {
                        if ($nodes{$node} == 1) {
                            push @failurenodes, $node;
                        }
                    }
                    my $rsp = {};
                    $rsp->{error}->[0] = "failed to run 'rsetboot' against the following nodes: @failurenodes";
                    $rsp->{errorcode}->[0] = 1;
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    @nodes = @successnodes;
                }
            }

            # Call "rpower" to start the node provision process
            %nodes = map { $_, 1 } @nodes;

            # Run rpower $noderange boot
            my @rpowerarg;
            push @rpowerarg, "boot";
            my $res =
              xCAT::Utils->runxcmd(
                {
                    command => ["rpower"],
                    node    => \@nodes,
                    arg     => \@rpowerarg
                },
                $subreq, -1, 1);

            $rc = $::RUNCMD_RC;
            my $rsp = {};
            if ($VERBOSE) {
                my @cmd = "Run command: rpower @nodes @rpowerarg";
                push @{ $rsp->{data} }, @cmd;
                push @{ $rsp->{data} }, @$res;
                xCAT::MsgUtils->message("I", $rsp, $callback);
            }
            unless ($rc == 0) {

                # We got an error with the rpower
                my @failurenodes;
                foreach my $line (@$res) {
                    $rsp->{data}->[0] = $line;
                    if (($line =~ /: on reset/) or ($line =~ /: off on/)) {
                        my $successnode;
                        my $restline;
                        ($successnode, $restline) = split(/:/, $line, 2);
                        $nodes{$successnode} = 0;
                    }
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
                foreach my $node (@nodes) {
                    if ($nodes{$node} == 1) {
                        push @failurenodes, $node;
                    }
                }
                my $rsp = {};
                $rsp->{error}->[0] = "failed to run 'rpower' against the following nodes: @failurenodes";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
            }
        }
    }

    # Check if they asked to bring up a console (-c) from rinstall always for winstall
    $req->{startconsole}->[0] = 0;
    if ($command =~ /rinstall/) {

        # For rinstall, the -c|--console option can provide the remote console for only 1 node
        if ($CONSOLE) {
            if (scalar @nodes != 1) {
                my $rsp = {};
                $rsp->{error}->[0] = "rinstall -c only accepts one node in the noderange. See winstall for support of consoles on multiple nodes.";
                $rsp->{errorcode}->[0] = 1;
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }
            else {
                # Tell rinstall client ok to start rcons
                $req->{startconsole}->[0] = 1;
            }
        }
    }
    elsif ($command =~ /winstall/) {

        # Command winstall can start a wcons command to multiple nodes for monitoring the provision cycle
        $req->{startconsole}->[0] = 1;
    }
    return 0;
}

#-------------------------------------------------------

=head3  Usage 


=cut

#-------------------------------------------------------
sub usage {
    my $command  = shift;
    my $callback = shift;
    my $rsp      = {};
    $rsp->{data}->[0] = "Usage:";
    $rsp->{data}->[1] = "   $command <noderange> boot | shell | runcmd=bmcsetup [-c|--console] [-u|--uefimode] [-V|--verbose]";
    $rsp->{data}->[2] = "   $command <noderange> osimage=<imagename> | -O <imagename> [--ignorekernelchk] [-c|--console] [-u|--uefimode] [-V|--verbose]";
    $rsp->{data}->[3] = "   $command [-h|--help|-v|--version]";
    xCAT::MsgUtils->message("I", $rsp, $callback);
}



1;
