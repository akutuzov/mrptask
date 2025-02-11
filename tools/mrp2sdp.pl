#!/usr/bin/env perl
# Reads the MRP JSON file.
# See http://mrp.nlpl.eu/index.php?page=4#format for a short description of the JSON graph format.
# See http://alt.qcri.org/semeval2015/task18/index.php?id=data-and-tools for the specification of the SDP 2015 file format.
# Copyright © 2019 Dan Zeman <zeman@ufal.mff.cuni.cz>
# License: GNU GPL

use utf8;
use open ':utf8';
binmode(STDIN, ':utf8');
binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');
use Getopt::Long;
use Carp;
# JSON::Parse is a third-party module available from CPAN.
# If you have Perl without JSON::Parse, try:
#   cpanm JSON::Parse
# If you don't have cpanm, try:
#   cpan JSON::Parse
use JSON::Parse ':all';

sub usage
{
    print STDERR ("Usage: perl mrp2sdp.pl --companion data/wsj.conllu < data/wsj.mrp > data/wsj.sdp\n");
    print STDERR ("       --cpn ... instead of SDP, output a CPN file required by one of the parsers\n");
}

my $companion; # path to the CoNLL-U file with lemmas, POS tags and dependencies from UDPipe (if available)
my $cpn = 0; # output a CPN file instead of the default SDP
GetOptions
(
    'companion=s' => \$companion,
    'cpn'         => \$cpn
);
my %companion;
if(defined($companion))
{
    print STDERR ("Reading the companion annotation...\n");
    # File handle COMPANION will be global and we will access it from functions.
    open(COMPANION, $companion) or confess("Cannot read $companion: $!");
    # The sentences in the companion data are not ordered by their ids.
    # Therefore we have to read them all in memory before accessing them.
    while(1)
    {
        my @conllu = read_companion_sentence();
        last if(scalar(@conllu) == 0);
        my $csid;
        if($conllu[0] =~ m/^\#(\d+)$/)
        {
            $csid = $1;
        }
        if(!defined($csid))
        {
            confess("Unknown id of the companion sentence");
        }
        $companion{$csid} = \@conllu;
    }
    print STDERR ("... done.\n");
}
elsif($cpn)
{
    die("Cannot output the CPN file if there is no companion data");
}

# Individual input lines are complete JSON structures (sentence graphs).
# The entire file is not valid JSON because the lines are not enclosed in an array and there are no commas at the ends of lines.
while(<>)
{
    my $jgraph = parse_json($_);
    # Read the companion data and merge it with the main graph.
    if(defined($companion))
    {
        get_sentence_companion($jgraph, \%companion);
    }
    my ($tokens, $gc2t) = get_tokens_for_graph($jgraph);
    my @tokens = @{$tokens};
    my @gc2t = @{$gc2t};
    # Map node ids to node objects.
    my %nodeidmap;
    foreach my $node (@{$jgraph->{nodes}})
    {
        $nodeidmap{$node->{id}} = $node;
    }
    # For each node, save the incoming edges.
    foreach my $edge (@{$jgraph->{edges}})
    {
        my $parent = $nodeidmap{$edge->{source}};
        my $child = $nodeidmap{$edge->{target}};
        die if(!defined($parent));
        die if(!defined($child));
        # A node is predicate if it has outgoing edges.
        $parent->{is_pred} = 1;
        my %record =
        (
            'parent' => $parent,
            'label'  => $edge->{label}
        );
        push(@{$child->{iedges}}, \%record);
    }
    # For each predicate, remember its order among predicates.
    my $predord = 0;
    foreach my $node (@{$jgraph->{nodes}})
    {
        if($node->{is_pred})
        {
            $node->{predord} = $predord++;
        }
    }
    my $npred = $predord;
    # Print the sentence graph in the SDP 2015 format.
    print("\#$jgraph->{id}\n");
    #print("\# text = $jgraph->{input}\n"); # this is not part of the SDP format
    for(my $i = 0; $i <= $#tokens; $i++)
    {
        my $id = $tokens[$i]{surfid};
        my $form = $tokens[$i]{text};
        # While we may have tokens with spaces, the SDP format cannot accommodate them.
        $form =~ s/\s//g;
        $form = '_' if($form eq '');
        my $lemma = $tokens[$i]{lemma};
        my $pos = '_';
        if(0) # POS tags from JSON, if available (only for nodes).
        {
            if($tokens[$i]{is_node} && $tokens[$i]{properties}[0] eq 'pos')
            {
                $pos = $tokens[$i]{values}[0];
            }
        }
        else # XPOS tags from companion annotation (predicted by UDPipe for all tokens)
        {
            $pos = $tokens[$i]{xpos};
        }
        if($cpn)
        {
            # Sample of a CPN file:
            # /home/droganova/work/Data_for_Enhancer/NeurboParser/semeval2015_data/train/en.sb.bn.cpn
            my $head = $tokens[$i]{head};
            my $deprel = $tokens[$i]{deprel};
            print("$pos\t$head\t$deprel\n");
        }
        else
        {
            my $top = ($tokens[$i]{is_node} && grep {$_ == $tokens[$i]{id}} (@{$jgraph->{tops}})) ? '+' : '-';
            my $pred = $tokens[$i]{is_pred} ? '+' : '-';
            my $frame = '_';
            if($tokens[$i]{is_node} && $tokens[$i]{properties}[1] eq 'frame')
            {
                $frame = $tokens[$i]{values}[1];
            }
            my @iemap = map {'_'} (1..$npred);
            if($tokens[$i]{is_node})
            {
                foreach my $iedge (@{$tokens[$i]{iedges}})
                {
                    my $pord = $iedge->{parent}{predord};
                    die if(!defined($pord));
                    die if($iemap[$pord] ne '_');
                    $iemap[$pord] = $iedge->{label};
                }
            }
            my $args = '';
            if(scalar(@iemap) > 0)
            {
                $args = "\t".join("\t", @iemap);
            }
            print("$id\t$form\t$lemma\t$pos\t$top\t$pred\t$frame$args\n");
        }
    }
    print("\n");
}



#------------------------------------------------------------------------------
# Finds tokenization consistent with the anchors of the nodes. Returns the
# reference to the list of tokens (hashes), and the reference to character-to-
# token mapping.
#------------------------------------------------------------------------------
sub get_tokens_for_graph
{
    my $jgraph = shift;
    my $input = $jgraph->{input}; # the input sentence, surface text
    my $nodes = $jgraph->{nodes}; # arrayref, graph nodes
    my @input = split(//, $input);
    my @nodes = @{$nodes};
    # Global projection from characters to corresponding token objects.
    # N-th position in the array corresponds to the n-th input character.
    # The value at the n-th position is undefined if the character is not (yet) part of any token.
    # Otherwise it is a hash reference. The target hash is either a graph node,
    # or a simple surface token (padding) that is not part of the graph structure.
    my @gc2t = map {undef} (@input);
    foreach my $node (@nodes)
    {
        foreach my $anchor (@{$node->{anchors}})
        {
            # In JSON the range is right-open, i.e., 'to' is the first character after the span.
            # In contrast, we understand 'to' as the index of the last character that is included.
            my $f = $anchor->{from};
            my $t = $anchor->{to}-1;
            for(my $i = $f; $i <= $t; $i++)
            {
                if(defined($gc2t[$i]))
                {
                    print STDERR ("WARNING: Multiple nodes are anchored to character $i.\n");
                }
                $gc2t[$i] = $node;
            }
        }
    }
    my @paddings;
    my ($current_text, $current_from, $current_to);
    for(my $i = 0; $i <= $#input + 1; $i++)
    {
        if((defined($gc2t[$i]) || $i > $#input) && defined($current_text))
        {
            my $modified_text = $current_text;
            $modified_text =~ s/^\s+//;
            $modified_text =~ s/\s+$//;
            $modified_text =~ s/\s+/ /g;
            unless($modified_text eq '')
            {
                my @tokens;
                if(exists($jgraph->{ctokens}))
                {
                    @tokens = get_external_tokens($current_text, $current_from, $current_to, $jgraph->{ctokens});
                }
                else
                {
                    @tokens = tokenize($modified_text);
                }
                my ($t2c, $c2t) = map_tokens_to_string($current_text, @tokens);
                # Sanity check.
                if(scalar(@{$c2t}) != $current_to-$current_from+1)
                {
                    confess("Incorrect length of \$c2t");
                }
                # Project the local map to the global map.
                my @records;
                for(my $j = 0; $j <= $#tokens; $j++)
                {
                    my %record =
                    (
                        'text' => $tokens[$j],
                        'from' => $current_from + $t2c->[$j][0],
                        'to'   => $current_from + $t2c->[$j][1]
                    );
                    push(@records, \%record);
                    push(@paddings, \%record);
                }
                for(my $j = $current_from; $j <= $current_to; $j++)
                {
                    my $itok = $c2t[$j-$current_from];
                    if($itok>0)
                    {
                        $itok--;
                        $gc2t[$j] = $records[$itok];
                    }
                }
            }
            $current_text = undef;
            $current_from = undef;
            $current_to = undef;
        }
        if(!defined($gc2t[$i]) && $i <= $#input)
        {
            if(!defined($current_from))
            {
                $current_from = $i;
            }
            $current_to = $i;
            $current_text .= $input[$i];
        }
    }
    # Combine nodes and paddings in one array.
    my @tokens;
    foreach my $node (@nodes)
    {
        # Make sure we can tell apart nodes from paddings.
        $node->{is_node} = 1;
        $node->{start} = -1;
        # It would be natural for us to assume that every node is anchored to
        # just one contiguous span of characters but it is not necessarily the
        # case. Let us see whether and how often a node is unanchored, or
        # anchored to multiple disjoint character spans.
        my $nanchors = scalar(@{$node->{anchors}});
        unless($nanchors == 1)
        {
            print STDERR ("WARNING: Node has $nanchors anchors.\n");
        }
        my @surfaces;
        foreach my $anchor (@{$node->{anchors}})
        {
            my $f = $anchor->{from};
            my $t = $anchor->{to}-1;
            if($node->{start} == -1 || $node->{start} > $f)
            {
                $node->{start} = $f;
            }
            my $surface = substr($input, $f, $t-$f+1);
            push(@surfaces, $surface);
        }
        $node->{text} = join('_', @surfaces);
        # We rely on the fact that tokens in SDP cannot contain spaces (unlike in UD).
        # However, in the JSON file they sometimes do (e.g. ". . ."); so we must replace them with underscores.
        $node->{text} =~ s/\s/_/g;
        push(@tokens, $node);
    }
    foreach my $padding (@paddings)
    {
        $padding->{is_node} = 0;
        $padding->{start} = $padding->{from};
        push(@tokens, $padding);
    }
    @tokens = sort {$a->{start} <=> $b->{start}} (@tokens);
    # Sanity check. We ordered nodes by their starting position in the surface string.
    # Are they also ordered by their ids?
    # At the same time, remember the surface id (includes both nodes and non-nodes) of each token.
    my $last_id = -1;
    for(my $i = 0; $i <= $#tokens; $i++)
    {
        my $token = $tokens[$i];
        $token->{surfid} = $i+1;
        if($token->{is_node})
        {
            # Note that there are examples of sentences where some id numbers are skipped.
            # For instance in DM, the original id from the full sentence was retained but some original tokens are not graph nodes.
            if($token->{id} <= $last_id)
            {
                print STDERR ("Last id = $last_id; current id = $token->{id}\n");
                confess("Unexpected ordering or ids of graph nodes");
            }
            $last_id = $token->{id};
        }
    }
    ###!!! Hypothesis: Maybe we have the same number of tokens as the companion data.
    ###!!! If so, then we can probably directly copy the lemmas and POS tags from UDPipe.
    my $njt = scalar(@tokens);
    my $nct = scalar(@{$jgraph->{ctokens}});
    if($njt != $nct)
    {
        print STDERR ("JSON has $njt tokens, companion has $nct.\n");
        print STDERR ("WARNING: This mismatch means that we will copy lemmas and POS tags to wrong tokens!\n");
    }
    for(my $i = 0; $i <= $#tokens; $i++)
    {
        # The target token has an id only if it is a node of the JSON graph (and not a padding).
        # Node ids start with 0 while surface tokens in CoNLL-U files start with 1, we have to take this in account.
        if(defined($tokens[$i]{id}) && $tokens[$i]{id} != $jgraph->{ctokens}[$i]{id}-1)
        {
            print STDERR ("WARNING: Copying data from a companion token whose id '$jgraph->{ctokens}[$i]{id}' does not match the id of the main token '$tokens[$i]{id}'.\n");
        }
        $tokens[$i]{lemma}  = $jgraph->{ctokens}[$i]{lemma};
        $tokens[$i]{upos}   = $jgraph->{ctokens}[$i]{upos};
        $tokens[$i]{xpos}   = $jgraph->{ctokens}[$i]{xpos};
        $tokens[$i]{head}   = $jgraph->{ctokens}[$i]{head};
        $tokens[$i]{deprel} = $jgraph->{ctokens}[$i]{deprel};
    }
    return (\@tokens, \@gc2t);
}



#------------------------------------------------------------------------------
# Takes an input string and returns the list of tokens in the string. This is
# a naive tokenizer. We may want to replace it with something more sophistica-
# ted, such as reading tokenized output of UDPipe.
#------------------------------------------------------------------------------
sub tokenize
{
    my $string = shift;
    $string =~ s/(\pP)/ $1 /g;
    $string =~ s/^\s+//s;
    $string =~ s/\s+$//s;
    $string =~ s/\s+/ /sg;
    my @tokens = split(/\s+/, $string);
    return @tokens;
}



#------------------------------------------------------------------------------
# An alternative to our own tokenization. Takes a substring, its character span
# in the original string, list of tokens and their spans provided by an exter-
# nal tokenizer. Returns the tokens that correspond to our substring.
#------------------------------------------------------------------------------
sub get_external_tokens
{
    my $string = shift;
    my $cf = shift;
    my $ct = shift;
    my $tokens = shift;
    my @tokens = @{$tokens};
    my $n = scalar(@tokens);
    @tokens = grep {$_->{from}<=$cf && $_->{to}>=$ct || $_->{from}>=$cf && $_->{from}<=$ct || $_->{to}>=$cf && $_->{to}<=$ct} (@tokens);
    @tokens = sort {$a->{from} <=> $b->{from}} (@tokens);
    if(scalar(@tokens)==0 || $tokens[0]{from}<$cf || $tokens[-1]{to}>$ct)
    {
        print STDERR ("String to tokenize: '$string' (span $cf..$ct)\n");
        print STDERR ("Companion tokens:   ".join(' ', map {$_->{text}.':'.$_->{from}.':'.$_->{to}} (@tokens))."\n\n");
        ###!!! We may want to die here because we are not prepared for tokens that expand beyond the current string.
        die;
    }
    return map {$_->{text}} (@tokens);
}



#------------------------------------------------------------------------------
# Takes an input string and a list of tokens that constitute a tokenization of
# the input string. The tokens must be ordered as in the input string, and they
# must contain all non-whitespace characters of the string. They may also
# contain whitespace characters but they cannot start or end with a whitespace.
# The function returns for each token a from-to anchor (character indices,
# starting with 0). It also returns a list of inverse references, from each
# character to its token (token indices start with 1, and 0 is used for
# whitespace characters that do not correspond to any token).
#------------------------------------------------------------------------------
sub map_tokens_to_string
{
    my $string = shift;
    my @tokens = @_;
    my @anchors;
    my @c2t = map {0} (1..length($string));
    my $is = 0;
    for(my $i = 0; $i <= $#tokens; $i++)
    {
        # Tokens can contain spaces but they must start and end with a non-space character.
        if($tokens[$i] =~ m/^\s/ || $tokens[$i] =~ m/\s$/)
        {
            confess("Token '$tokens[$i]' starts or ends with whitespace");
        }
        # Remove leading whitespace in the string.
        my $lsbefore = length($string);
        $string =~ s/^\s+//;
        my $lsafter = length($string);
        $is += $lsbefore-$lsafter;
        # Verify that the string now begins with the next token.
        my $l = length($tokens[$i]);
        my $strstart = substr($string, 0, $l);
        if($strstart ne $tokens[$i])
        {
            confess("Mismatch: next token is '$tokens[$i]' but the remainder of the string is '$string'");
        }
        # Now we know the character span of the token in the string.
        my $f = $is;
        my $t = $is+$l-1;
        push(@anchors, [$f, $t]);
        my $itok = $i+1;
        for(my $j = $f; $j <= $t; $j++)
        {
            $c2t[$j] = $itok;
        }
        # Consume the token we just mapped.
        $string = substr($string, $l);
        $is += $l;
    }
    return (\@anchors, \@c2t);
}



#------------------------------------------------------------------------------
# Reads a dependency tree from the companion CoNLL-U file.
#------------------------------------------------------------------------------
sub read_companion_sentence
{
    my @sentence;
    my $line;
    while($line = <COMPANION>)
    {
        last if($line =~ m/^\s*$/);
        $line =~ s/\r?\n$//;
        push(@sentence, $line);
    }
    # Empty @sentence signals the end of the file.
    return @sentence;
}



#------------------------------------------------------------------------------
# Takes companion data for a given sentence and prepares it for exploitation.
#------------------------------------------------------------------------------
sub get_sentence_companion
{
    my $jgraph = shift;
    my $companion = shift; # hash reference indexed by sentence ids
    if(!exists($companion->{$jgraph->{id}}))
    {
        confess("Cannot find companion annotation of input sentence '$jgraph->{id}'");
    }
    # Sanity check: do the companion tokens match the input string from JSON?
    my @tokenlines = grep {m/^\d/} (@{$companion->{$jgraph->{id}}});
    my @ctokens = map {my @f = split(/\t/, $_); $f[1]} (@tokenlines);
    # UDPipe seems to have been applied to unnormalized text while the input strings in JSON underwent some normalization.
    # Try to normalize the UDPipe word forms so we can match them.
    # Do not use map() because we may need to look at the neighboring token.
    my @mtokens;
    for(my $i = 0; $i <= $#ctokens; $i++)
    {
        my $x = $ctokens[$i];
        $x =~ s/[“”]/"/g; # "
        $x =~ s/’/'/g; # '
        $x =~ s/‘/`/g; # `
        $x =~ s/–/--/g;
        # Handling of periods is not consistent; there is at least one example of '....' in the data, corresponding to '….'.
        # Unfortunately, we cannot base our heuristic on observing four periods because elsewhere, '….' is normalized as '. . . .'
        # So we will simply check the input string (hopefully there is at most one occurrence of '. . .')
        if($jgraph->{input} =~ m/\. \. \./)
        {
            $x =~ s/…/. . ./g;
        }
        else
        {
            $x =~ s/…/.../g;
        }
        push(@mtokens, $x);
    }
    my ($t2c, $c2t) = map_tokens_to_string($jgraph->{input}, @mtokens);
    my @tokenranges = map {my @f = split(/\t/, $_); $f[9] =~ m/TokenRange=(\d+):(\d+)/; [$1, $2-1]} (@tokenlines);
    for(my $i = 0; $i <= $#tokenranges; $i++)
    {
        # Due to the normalizations, this error is almost guaranteed to occur and we cannot die on it in the final version.
        if($tokenranges[$i][0] != $t2c->[$i][0] || $tokenranges[$i][1] != $t2c->[$i][1])
        {
            # Known problems: UDPipe splits '")' to '"' and ')' but assigns TokenRange=126:127 to both.
            # For '. . .', it includes the following space in the token ('. . . ').
            #unless($mtokens[$i] eq '"' && $mtokens[$i+1] eq ')' || $mtokens[$i] eq '. . .')
            unless($mtokens[$i] eq '. . .') # This version will print the ") errors for Stephan Oepen.
            {
                print STDERR ("sent_id $jgraph->{id}\n");
                print STDERR ("JSON:   $jgraph->{input}\n");
                print STDERR ("Tokens: ".join(' ', @ctokens)."\n");
                print STDERR ("MToks:  ".join(' ', @mtokens)."\n");
                print STDERR ("Jt2c:   ".join(' ', map {"$_->[0]:$_->[1]"} (@{$t2c}))."\n");
                print STDERR ("Ut2c:   ".join(' ', map {"$_->[0]:$_->[1]"} (@tokenranges))."\n");
                print STDERR ("Mismatch in character anchors: $tokenranges[$i][0]:$tokenranges[$i][1] vs. $t2c->[$i][0]:$t2c->[$i][1] for token $i\n\n");
                ###!!!die;
            }
            last; # If we survived, do not report subsequent errors in this sentence.
        }
    }
    # Restructure tokens as hashes that contain both the text and its character span.
    my @tokens;
    for(my $i = 0; $i <= $#mtokens; $i++)
    {
        my @f = split(/\t/, $tokenlines[$i]);
        my %record =
        (
            'text'   => $mtokens[$i],
            'from'   => $t2c->[$i][0],
            'to'     => $t2c->[$i][1],
            'ctext'  => $ctokens[$i],
            'lemma'  => $f[2],
            'upos'   => $f[3],
            'xpos'   => $f[4],
            'id'     => $f[0],
            'head'   => $f[6],
            'deprel' => $f[7]
        );
        push(@tokens, \%record);
    }
    # Instead of returning the values, store them directly in %jgraph.
    $jgraph->{ctlines} = \@tokenlines;
    $jgraph->{ctokens} = \@tokens;
    ###!!! DEBUGGING
    #print STDERR ("Companion tokens: ".join(' ', map {$_->{text}.':'.$_->{from}.':'.$_->{to}} (@tokens))."\n");
}
