package Slic3r::Print::Object;
use Moo;

use List::Util qw(min sum);
use Slic3r::ExtrusionPath ':roles';
use Slic3r::Geometry qw(Z PI scale unscale deg2rad rad2deg scaled_epsilon);
use Slic3r::Geometry::Clipper qw(diff_ex intersection_ex union_ex);
use Slic3r::Surface ':types';

has 'print'             => (is => 'ro', weak_ref => 1, required => 1);
has 'input_file'        => (is => 'rw', required => 0);
has 'meshes'            => (is => 'rw', default => sub { [] });  # by region_id
has 'size'              => (is => 'rw', required => 1);
has 'copies'            => (is => 'rw', default => sub {[ [0,0] ]});
has 'layers'            => (is => 'rw', default => sub { [] });

sub BUILD {
    my $self = shift;
 	 
    # make layers
    while (!@{$self->layers} || $self->layers->[-1]->slice_z < $self->size->[Z]) {
        push @{$self->layers}, Slic3r::Layer->new(
            object  => $self,
            id      => $#{$self->layers} + 1,
        );
    }
}

sub layer_count {
    my $self = shift;
    return scalar @{ $self->layers };
}

sub get_layer_range {
    my $self = shift;
    my ($min_z, $max_z) = @_;
    
    # $min_layer is the uppermost layer having slice_z <= $min_z
    # $max_layer is the lowermost layer having slice_z >= $max_z
    my ($min_layer, $max_layer) = (0, undef);
    for my $i (0 .. $#{$self->layers}) {
        if ($self->layers->[$i]->slice_z >= $min_z) {
            $min_layer = $i - 1;
            for my $k ($i .. $#{$self->layers}) {
                if ($self->layers->[$k]->slice_z >= $max_z) {
                    $max_layer = $k - 1;
                    last;
                }
            }
            last;
        }
    }
    return ($min_layer, $max_layer);
}

sub slice {
    my $self = shift;
    my %params = @_;
    
    # process facets
    for my $region_id (0 .. $#{$self->meshes}) {
        my $mesh = $self->meshes->[$region_id];  # ignore undef meshes
        
        my $apply_lines = sub {
            my $lines = shift;
            foreach my $layer_id (keys %$lines) {
                my $layerm = $self->layers->[$layer_id]->region($region_id);
                push @{$layerm->lines}, @{$lines->{$layer_id}};
            }
        };
        Slic3r::parallelize(
            disable => ($#{$mesh->facets} < 500),  # don't parallelize when too few facets
            items => [ 0..$#{$mesh->facets} ],
            thread_cb => sub {
                my $q = shift;
                my $result_lines = {};
                while (defined (my $facet_id = $q->dequeue)) {
                    my $lines = $mesh->slice_facet($self, $facet_id);
                    foreach my $layer_id (keys %$lines) {
                        $result_lines->{$layer_id} ||= [];
                        push @{ $result_lines->{$layer_id} }, @{ $lines->{$layer_id} };
                    }
                }
                return $result_lines;
            },
            collect_cb => sub {
                $apply_lines->($_[0]);
            },
            no_threads_cb => sub {
                for (0..$#{$mesh->facets}) {
                    my $lines = $mesh->slice_facet($self, $_);
                    $apply_lines->($lines);
                }
            },
        );
    }
    die "Invalid input file\n" if !@{$self->layers};
    
    # free memory
    $self->meshes(undef) unless $params{keep_meshes};
    
    # remove last layer if empty
    # (we might have created it because of the $max_layer = ... + 1 code in TriangleMesh)
    pop @{$self->layers} if !map @{$_->lines}, @{$self->layers->[-1]->regions};
    
    foreach my $layer (@{ $self->layers }) {
        # make sure all layers contain layer region objects for all regions
        $layer->region($_) for 0 .. ($self->print->regions_count-1);
        
        Slic3r::debugf "Making surfaces for layer %d (slice z = %f):\n",
            $layer->id, unscale $layer->slice_z if $Slic3r::debug;
        
        # layer currently has many lines representing intersections of
        # model facets with the layer plane. there may also be lines
        # that we need to ignore (for example, when two non-horizontal
        # facets share a common edge on our plane, we get a single line;
        # however that line has no meaning for our layer as it's enclosed
        # inside a closed polyline)
        
        # build surfaces from sparse lines
        foreach my $layerm (@{$layer->regions}) {
            my ($slicing_errors, $loops) = Slic3r::TriangleMesh::make_loops($layerm->lines);
            $layer->slicing_errors(1) if $slicing_errors;
            $layerm->make_surfaces($loops);
            
            # free memory
            $layerm->lines(undef);
        }
        
        # merge all regions' slices to get islands
        $layer->make_slices;
    }
    
    # detect slicing errors
    my $warning_thrown = 0;
    for my $i (0 .. $#{$self->layers}) {
        my $layer = $self->layers->[$i];
        next unless $layer->slicing_errors;
        if (!$warning_thrown) {
            warn "The model has overlapping or self-intersecting facets. I tried to repair it, "
                . "however you might want to check the results or repair the input file and retry.\n";
            $warning_thrown = 1;
        }
        
        # try to repair the layer surfaces by merging all contours and all holes from
        # neighbor layers
        Slic3r::debugf "Attempting to repair layer %d\n", $i;
        
        foreach my $region_id (0 .. $#{$layer->regions}) {
            my $layerm = $layer->region($region_id);
            
            my (@upper_surfaces, @lower_surfaces);
            for (my $j = $i+1; $j <= $#{$self->layers}; $j++) {
                if (!$self->layers->[$j]->slicing_errors) {
                    @upper_surfaces = @{$self->layers->[$j]->region($region_id)->slices};
                    last;
                }
            }
            for (my $j = $i-1; $j >= 0; $j--) {
                if (!$self->layers->[$j]->slicing_errors) {
                    @lower_surfaces = @{$self->layers->[$j]->region($region_id)->slices};
                    last;
                }
            }
            
            my $union = union_ex([
                map $_->expolygon->contour, @upper_surfaces, @lower_surfaces,
            ]);
            my $diff = diff_ex(
                [ map @$_, @$union ],
                [ map $_->expolygon->holes, @upper_surfaces, @lower_surfaces, ],
            );
            
            @{$layerm->slices} = map Slic3r::Surface->new
                (expolygon => $_, surface_type => S_TYPE_INTERNAL),
                @$diff;
        }
            
        # update layer slices after repairing the single regions
        $layer->make_slices;
    }
    
    # remove empty layers from bottom
    my $first_object_layer_id = $Slic3r::Config->raft_layers;
    while (@{$self->layers} && !@{$self->layers->[$first_object_layer_id]->slices} && !map @{$_->thin_walls}, @{$self->layers->[$first_object_layer_id]->regions}) {
        splice @{$self->layers}, $first_object_layer_id, 1;
        for (my $i = $first_object_layer_id; $i <= $#{$self->layers}; $i++) {
            $self->layers->[$i]->id($i);
        }
    }
    
    warn "No layers were detected. You might want to repair your STL file and retry.\n"
        if !@{$self->layers};
}

sub make_perimeters {
    my $self = shift;
    
    # compare each layer to the one below, and mark those slices needing
    # one additional inner perimeter, like the top of domed objects-
    
    # this algorithm makes sure that at least one perimeter is overlapping
    # but we don't generate any extra perimeter if fill density is zero, as they would be floating
    # inside the object - infill_only_where_needed should be the method of choice for printing
    # hollow objects
    if ($Slic3r::Config->extra_perimeters && $Slic3r::Config->perimeters > 0 && $Slic3r::Config->fill_density > 0) {
        for my $region_id (0 .. ($self->print->regions_count-1)) {
            for my $layer_id (0 .. $self->layer_count-2) {
                my $layerm          = $self->layers->[$layer_id]->regions->[$region_id];
                my $upper_layerm    = $self->layers->[$layer_id+1]->regions->[$region_id];
                my $perimeter_spacing       = $layerm->perimeter_flow->scaled_spacing;
                
                my $overlap = $perimeter_spacing;  # one perimeter
                
                # compute the polygon used to trigger the additional perimeters: the hole represents
                # the required overlap, while the contour represents how different should the slices be 
                # (thus how horizontal should the slope be) before extra perimeters are not generated, and
                # normal solid infill is used
                my $upper = diff_ex(
                    [ map @$_, map $_->expolygon->offset_ex($overlap), @{$upper_layerm->slices} ],
                    [ map @$_, map $_->expolygon->offset_ex(-$overlap), @{$upper_layerm->slices} ],
                );
                next if !@$upper;
                
                foreach my $slice (@{$layerm->slices}) {
                    my $hypothetical_perimeter_num = $Slic3r::Config->perimeters + 1;
                    CYCLE: while (1) {
                        # compute polygons representing the thickness of the hypotetical new internal perimeter
                        # of our slice
                        my $hypothetical_perimeter;
                        {
                            my $outer = [ map @$_, $slice->expolygon->offset_ex(- ($hypothetical_perimeter_num-1) * $perimeter_spacing - scaled_epsilon) ];
                            last CYCLE if !@$outer;
                            my $inner = [ map @$_, $slice->expolygon->offset_ex(- $hypothetical_perimeter_num * $perimeter_spacing) ];
                            last CYCLE if !@$inner;
                            $hypothetical_perimeter = diff_ex($outer, $inner);
                        }
                        last CYCLE if !@$hypothetical_perimeter;
                        
                        # compute the area of the hypothetical perimeter
                        my $hp_area = sum(map $_->area, @$hypothetical_perimeter);
                        
                        # only add the perimeter if the intersection is at least 20%, otherwise we'd get no benefit
                        my $intersection = intersection_ex([ map @$_, @$upper ], [ map @$_, @$hypothetical_perimeter ]);
                        last CYCLE if (sum(map $_->area, @{ $intersection }) // 0) < $hp_area * 0.2;
                        Slic3r::debugf "  adding one more perimeter at layer %d\n", $layer_id;
                        $slice->additional_inner_perimeters(($slice->additional_inner_perimeters || 0) + 1);
                        $hypothetical_perimeter_num++;
                    }
                }
            }
        }
    }
    
    Slic3r::parallelize(
        items => sub { 0 .. ($self->layer_count-1) },
        thread_cb => sub {
            my $q = shift;
            $Slic3r::Geometry::Clipper::clipper = Math::Clipper->new;
            my $result = {};
            while (defined (my $layer_id = $q->dequeue)) {
                my $layer = $self->layers->[$layer_id];
                $layer->make_perimeters;
                $result->{$layer_id} ||= {};
                foreach my $region_id (0 .. $#{$layer->regions}) {
                    my $layerm = $layer->regions->[$region_id];
                    $result->{$layer_id}{$region_id} = {
                        perimeters      => $layerm->perimeters,
                        fill_surfaces   => $layerm->fill_surfaces,
                        thin_fills      => $layerm->thin_fills,
                    };
                }
            }
            return $result;
        },
        collect_cb => sub {
            my $result = shift;
            foreach my $layer_id (keys %$result) {
                foreach my $region_id (keys %{$result->{$layer_id}}) {
                    $self->layers->[$layer_id]->regions->[$region_id]->$_($result->{$layer_id}{$region_id}{$_})
                        for qw(perimeters fill_surfaces thin_fills);
                }
            }
        },
        no_threads_cb => sub {
            $_->make_perimeters for @{$self->layers};
        },
    );
}

sub detect_surfaces_type {
    my $self = shift;
    Slic3r::debugf "Detecting solid surfaces...\n";
    
    # prepare a reusable subroutine to make surface differences
    my $surface_difference = sub {
        my ($subject_surfaces, $clip_surfaces, $result_type, $layerm) = @_;
        my $expolygons = diff_ex(
            [ map @$_, @$subject_surfaces ],
            [ map @$_, @$clip_surfaces ],
            1,
        );
        return grep $_->contour->is_printable($layerm->perimeter_flow),
            map Slic3r::Surface->new(expolygon => $_, surface_type => $result_type), 
            @$expolygons;
    };
    
    for my $region_id (0 .. ($self->print->regions_count-1)) {
        for my $i (0 .. ($self->layer_count-1)) {
            my $layerm = $self->layers->[$i]->regions->[$region_id];
            
            # comparison happens against the *full* slices (considering all regions)
            my $upper_layer = $self->layers->[$i+1];
            my $lower_layer = $i > 0 ? $self->layers->[$i-1] : undef;
            
            my (@bottom, @top, @internal) = ();
            
            # find top surfaces (difference between current surfaces
            # of current layer and upper one)
            if ($upper_layer) {
                @top = $surface_difference->(
                    [ map $_->expolygon, @{$layerm->slices} ],
                    $upper_layer->slices,
                    S_TYPE_TOP,
                    $layerm,
                );
            } else {
                # if no upper layer, all surfaces of this one are solid
                @top = @{$layerm->slices};
                $_->surface_type(S_TYPE_TOP) for @top;
            }
            
            # find bottom surfaces (difference between current surfaces
            # of current layer and lower one)
            if ($lower_layer) {
                # lower layer's slices are already Surface objects
                @bottom = $surface_difference->(
                    [ map $_->expolygon, @{$layerm->slices} ],
                    $lower_layer->slices,
                    S_TYPE_BOTTOM,
                    $layerm,
                );
            } else {
                # if no lower layer, all surfaces of this one are solid
                @bottom = @{$layerm->slices};
                $_->surface_type(S_TYPE_BOTTOM) for @bottom;
            }
            
            # now, if the object contained a thin membrane, we could have overlapping bottom
            # and top surfaces; let's do an intersection to discover them and consider them
            # as bottom surfaces (to allow for bridge detection)
            if (@top && @bottom) {
                my $overlapping = intersection_ex([ map $_->p, @top ], [ map $_->p, @bottom ]);
                Slic3r::debugf "  layer %d contains %d membrane(s)\n", $layerm->id, scalar(@$overlapping);
                @top = $surface_difference->([map $_->expolygon, @top], $overlapping, S_TYPE_TOP, $layerm);
            }
            
            # find internal surfaces (difference between top/bottom surfaces and others)
            @internal = $surface_difference->(
                [ map $_->expolygon, @{$layerm->slices} ],
                [ map $_->expolygon, @top, @bottom ],
                S_TYPE_INTERNAL,
                $layerm,
            );
            
            # save surfaces to layer
            @{$layerm->slices} = (@bottom, @top, @internal);
            
            Slic3r::debugf "  layer %d has %d bottom, %d top and %d internal surfaces\n",
                $layerm->id, scalar(@bottom), scalar(@top), scalar(@internal);
        }
        
        # clip surfaces to the fill boundaries
        foreach my $layer (@{$self->layers}) {
            my $layerm = $layer->regions->[$region_id];
            my $fill_boundaries = [ map @$_, @{$layerm->fill_surfaces} ];
            @{$layerm->fill_surfaces} = ();
            foreach my $surface (@{$layerm->slices}) {
                my $intersection = intersection_ex(
                    [ $surface->p ],
                    $fill_boundaries,
                );
                push @{$layerm->fill_surfaces}, map Slic3r::Surface->new
                    (expolygon => $_, surface_type => $surface->surface_type),
                    @$intersection;
            }
        }
    }
}

sub clip_fill_surfaces {
    my $self = shift;
    return unless $Slic3r::Config->infill_only_where_needed;
    
    # We only want infill under ceilings; this is almost like an
    # internal support material.
    
    my $additional_margin = scale 3;
    
    my @overhangs = ();
    for my $layer_id (reverse 0..$#{$self->layers}) {
        my $layer = $self->layers->[$layer_id];
        
        # clip this layer's internal surfaces to @overhangs
        foreach my $layerm (@{$layer->regions}) {
            my @new_internal = map Slic3r::Surface->new(
                    expolygon       => $_,
                    surface_type    => S_TYPE_INTERNAL,
                ),
                @{intersection_ex(
                    [ map @$_, @overhangs ],
                    [ map @{$_->expolygon}, grep $_->surface_type == S_TYPE_INTERNAL, @{$layerm->fill_surfaces} ],
                )};
            @{$layerm->fill_surfaces} = (
                @new_internal,
                (grep $_->surface_type != S_TYPE_INTERNAL, @{$layerm->fill_surfaces}),
            );
        }
        
        # get this layer's overhangs
        if ($layer_id > 0) {
            my $lower_layer = $self->layers->[$layer_id-1];
            # loop through layer regions so that we can use each region's
            # specific overhang width
            foreach my $layerm (@{$layer->regions}) {
                my $overhang_width = $layerm->overhang_width;
                # we want to support any solid surface, not just tops
                # (internal solids might have been generated)
                push @overhangs, map $_->offset_ex($additional_margin), @{intersection_ex(
                    [ map @{$_->expolygon}, grep $_->surface_type != S_TYPE_INTERNAL, @{$layerm->fill_surfaces} ],
                    [ map @$_, map $_->offset_ex(-$overhang_width), @{$lower_layer->slices} ],
                )};
            }
        }
    }
}

sub bridge_over_infill {
    my $self = shift;
    
    for my $layer_id (1..$#{$self->layers}) {
        my $layer       = $self->layers->[$layer_id];
        my $lower_layer = $self->layers->[$layer_id-1];
        
        foreach my $layerm (@{$layer->regions}) {
            # compute the areas needing bridge math 
            my @internal_solid = grep $_->surface_type == S_TYPE_INTERNALSOLID, @{$layerm->fill_surfaces};
            my @lower_internal = grep $_->surface_type == S_TYPE_INTERNAL, map @{$_->fill_surfaces}, @{$lower_layer->regions};
            my $to_bridge = intersection_ex(
                [ map $_->p, @internal_solid ],
                [ map $_->p, @lower_internal ],
            );
            next unless @$to_bridge;
            Slic3r::debugf "Bridging %d internal areas at layer %d\n", scalar(@$to_bridge), $layer_id;
            
            # build the new collection of fill_surfaces
            {
                my @new_surfaces = grep $_->surface_type != S_TYPE_INTERNALSOLID, @{$layerm->fill_surfaces};
                push @new_surfaces, map Slic3r::Surface->new(
                        expolygon       => $_,
                        surface_type    => S_TYPE_INTERNALBRIDGE,
                    ), @$to_bridge;
                push @new_surfaces, map Slic3r::Surface->new(
                        expolygon       => $_,
                        surface_type    => S_TYPE_INTERNALSOLID,
                    ), @{diff_ex(
                        [ map $_->p, @internal_solid ],
                        [ map @$_, @$to_bridge ],
                    )};
                @{$layerm->fill_surfaces} = @new_surfaces;
            }
            
            # exclude infill from the layers below if needed
            # see discussion at https://github.com/alexrj/Slic3r/issues/240
            {
                my $excess = $layerm->extruders->{infill}->bridge_flow->width - $layerm->height;
                for (my $i = $layer_id-1; $excess >= $self->layers->[$i]->height; $i--) {
                    Slic3r::debugf "  skipping infill below those areas at layer %d\n", $i;
                    foreach my $lower_layerm (@{$self->layers->[$i]->regions}) {
                        my @new_surfaces = ();
                        # subtract the area from all types of surfaces
                        foreach my $group (Slic3r::Surface->group(@{$lower_layerm->fill_surfaces})) {
                            push @new_surfaces, map Slic3r::Surface->new(
                                expolygon       => $_,
                                surface_type    => $group->[0]->surface_type,
                            ), @{diff_ex(
                                [ map $_->p, @$group ],
                                [ map @$_, @$to_bridge ],
                            )};
                        }
                        @{$lower_layerm->fill_surfaces} = @new_surfaces;
                    }
                    
                    $excess -= $self->layers->[$i]->height;
                }
            }
        }
    }
}

sub discover_horizontal_shells {
    my $self = shift;
    
    Slic3r::debugf "==> DISCOVERING HORIZONTAL SHELLS\n";
    
    for my $region_id (0 .. ($self->print->regions_count-1)) {
        for (my $i = 0; $i < $self->layer_count; $i++) {
            my $layerm = $self->layers->[$i]->regions->[$region_id];
            
            if ($Slic3r::Config->solid_infill_every_layers && ($i % $Slic3r::Config->solid_infill_every_layers) == 0) {
                $_->surface_type(S_TYPE_INTERNALSOLID)
                    for grep $_->surface_type == S_TYPE_INTERNAL, @{$layerm->fill_surfaces};
            }
            
            foreach my $type (S_TYPE_TOP, S_TYPE_BOTTOM) {
                # find slices of current type for current layer
                my @surfaces = grep $_->surface_type == $type, @{$layerm->slices} or next;
                my $surfaces_p = [ map $_->p, @surfaces ];
                Slic3r::debugf "Layer %d has %d surfaces of type '%s'\n",
                    $i, scalar(@surfaces), ($type == S_TYPE_TOP ? 'top' : 'bottom');
                
                my $solid_layers = ($type == S_TYPE_TOP)
                    ? $Slic3r::Config->top_solid_layers
                    : $Slic3r::Config->bottom_solid_layers;
                for (my $n = $type == S_TYPE_TOP ? $i-1 : $i+1; 
                        abs($n - $i) <= $solid_layers-1; 
                        $type == S_TYPE_TOP ? $n-- : $n++) {
                    
                    next if $n < 0 || $n >= $self->layer_count;
                    Slic3r::debugf "  looking for neighbors on layer %d...\n", $n;
                    
                    my @neighbor_fill_surfaces  = @{$self->layers->[$n]->regions->[$region_id]->fill_surfaces};
                    
                    # find intersection between neighbor and current layer's surfaces
                    # intersections have contours and holes
                    my $new_internal_solid = intersection_ex(
                        $surfaces_p,
                        [ map $_->p, grep { $_->surface_type == S_TYPE_INTERNAL || $_->surface_type == S_TYPE_INTERNALSOLID } @neighbor_fill_surfaces ],
                        undef, 1,
                    );
                    next if !@$new_internal_solid;
                    
                    # internal-solid are the union of the existing internal-solid surfaces
                    # and new ones
                    my $internal_solid = union_ex([
                        ( map $_->p, grep $_->surface_type == S_TYPE_INTERNALSOLID, @neighbor_fill_surfaces ),
                        ( map @$_, @$new_internal_solid ),
                    ]);
                    
                    # subtract intersections from layer surfaces to get resulting inner surfaces
                    my $internal = diff_ex(
                        [ map $_->p, grep $_->surface_type == S_TYPE_INTERNAL, @neighbor_fill_surfaces ],
                        [ map @$_, @$internal_solid ],
                        1,
                    );
                    Slic3r::debugf "    %d internal-solid and %d internal surfaces found\n",
                        scalar(@$internal_solid), scalar(@$internal);
                    
                    # Note: due to floating point math we're going to get some very small
                    # polygons as $internal; they will be removed by removed_small_features()
                    
                    # assign resulting inner surfaces to layer
                    my $neighbor_fill_surfaces = $self->layers->[$n]->regions->[$region_id]->fill_surfaces;
                    @$neighbor_fill_surfaces = ();
                    push @$neighbor_fill_surfaces, Slic3r::Surface->new
                        (expolygon => $_, surface_type => S_TYPE_INTERNAL)
                        for @$internal;
                    
                    # assign new internal-solid surfaces to layer
                    push @$neighbor_fill_surfaces, Slic3r::Surface->new
                        (expolygon => $_, surface_type => S_TYPE_INTERNALSOLID)
                        for @$internal_solid;
                    
                    # assign top and bottom surfaces to layer
                    foreach my $s (Slic3r::Surface->group(grep { $_->surface_type == S_TYPE_TOP || $_->surface_type == S_TYPE_BOTTOM } @neighbor_fill_surfaces)) {
                        my $solid_surfaces = diff_ex(
                            [ map $_->p, @$s ],
                            [ map @$_, @$internal_solid, @$internal ],
                            1,
                        );
                        push @$neighbor_fill_surfaces, Slic3r::Surface->new
                            (expolygon => $_, surface_type => $s->[0]->surface_type, bridge_angle => $s->[0]->bridge_angle)
                            for @$solid_surfaces;
                    }
                }
            }
            
            my $area_threshold = $layerm->infill_area_threshold;
            @{$layerm->fill_surfaces} = grep $_->expolygon->area > $area_threshold, @{$layerm->fill_surfaces};
        }
        
        for (my $i = 0; $i < $self->layer_count; $i++) {
            my $layerm = $self->layers->[$i]->regions->[$region_id];
            
            # if hollow object is requested, remove internal surfaces
            if ($Slic3r::Config->fill_density == 0) {
                @{$layerm->fill_surfaces} = grep $_->surface_type != S_TYPE_INTERNAL, @{$layerm->fill_surfaces};
            }
        }
    }
}

# combine fill surfaces across layers
sub combine_infill {
    my $self = shift;
    return unless $Slic3r::Config->infill_every_layers > 1 && $Slic3r::Config->fill_density > 0;
    
    my $layer_count = $self->layer_count;
    for my $region_id (0 .. ($self->print->regions_count-1)) {
        # limit the number of combined layers to the maximum height allowed by this regions' nozzle
        my $every = min(
            $Slic3r::Config->infill_every_layers,
            int($self->print->regions->[$region_id]->extruders->{infill}->nozzle_diameter/$Slic3r::Config->layer_height),
        );
        Slic3r::debugf "Infilling every %d layers\n", $every;
        
        # skip bottom layer
        for (my $layer_id = $every; $layer_id <= $layer_count-1; $layer_id += $every) {
            # get the layers whose infill we want to combine (bottom-up)
            my @layerms = map $self->layers->[$_]->regions->[$region_id],
                ($layer_id - ($every-1)) .. $layer_id;
            
            # process internal and internal-solid infill separately
            for my $type (S_TYPE_INTERNAL, S_TYPE_INTERNALSOLID) {
                # we need to perform a multi-layer intersection, so let's split it in pairs
                
                # initialize the intersection with the candidates of the lowest layer
                my $intersection = [ map $_->expolygon, grep $_->surface_type == $type, @{$layerms[0]->fill_surfaces} ];
                
                # start looping from the second layer and intersect the current intersection with it
                for my $layerm (@layerms[1 .. $#layerms]) {
                    $intersection = intersection_ex(
                        [ map @$_, @$intersection ],
                        [ map @{$_->expolygon}, grep $_->surface_type == $type, @{$layerm->fill_surfaces} ],
                    );
                }
                
                my $area_threshold = $layerms[0]->infill_area_threshold;
                @$intersection = grep $_->area > $area_threshold, @$intersection;
                next if !@$intersection;
                Slic3r::debugf "  combining %d %s regions from layers %d-%d\n",
                    scalar(@$intersection),
                    ($type == S_TYPE_INTERNAL ? 'internal' : 'internal-solid'),
                    $layer_id-($every-1), $layer_id;
                
                # $intersection now contains the regions that can be combined across the full amount of layers
                # so let's remove those areas from all layers
                
                my @intersection_with_clearance = map $_->offset(
                      $layerms[-1]->infill_flow->scaled_width    / 2
                    + $layerms[-1]->perimeter_flow->scaled_width / 2
                    # Because fill areas for rectilinear and honeycomb are grown 
                    # later to overlap perimeters, we need to counteract that too.
                    + (($type == S_TYPE_INTERNALSOLID || $Slic3r::Config->fill_pattern =~ /(rectilinear|honeycomb)/)
                      ? $layerms[-1]->infill_flow->scaled_width * &Slic3r::PERIMETER_INFILL_OVERLAP_OVER_SPACING
                      : 0)
                    ), @$intersection;
                
                foreach my $layerm (@layerms) {
                    my @this_type   = grep $_->surface_type == $type, @{$layerm->fill_surfaces};
                    my @other_types = grep $_->surface_type != $type, @{$layerm->fill_surfaces};
                    
                    @this_type = map Slic3r::Surface->new(expolygon => $_, surface_type => $type),
                        @{diff_ex(
                            [ map @{$_->expolygon}, @this_type ],
                            [ @intersection_with_clearance ],
                        )};
                    
                    # apply surfaces back with adjusted depth to the uppermost layer
                    if ($layerm->id == $layer_id) {
                        push @this_type,
                            map Slic3r::Surface->new(expolygon => $_, surface_type => $type, depth_layers => $every),
                            @$intersection;
                    }
                    
                    @{$layerm->fill_surfaces} = (@this_type, @other_types);
                }
            }
        }
    }
}

sub generate_support_material {
    my $self = shift;
    return if $self->layer_count < 2;
    
    my $overhang_width;
    if ($Slic3r::Config->support_material_threshold) {
        my $threshold_rad = deg2rad($Slic3r::Config->support_material_threshold + 1);  # +1 makes the threshold inclusive
        Slic3r::debugf "Threshold angle = %d°\n", rad2deg($threshold_rad);
        $overhang_width = scale $Slic3r::Config->layer_height * ((cos $threshold_rad) / (sin $threshold_rad));
    } else {
        $overhang_width = $self->layers->[1]->regions->[0]->overhang_width;
    }
    my $flow                    = $self->print->support_material_flow;
    my $distance_from_object    = 1.5 * $flow->scaled_width;
    my $pattern_spacing = ($Slic3r::Config->support_material_spacing > $flow->spacing)
        ? $Slic3r::Config->support_material_spacing
        : $flow->spacing;
    
    # determine support regions in each layer (for upper layers)
    Slic3r::debugf "Detecting regions\n";
    my %layers = ();            # this represents the areas of each layer having to support upper layers (excluding interfaces)
    my %layers_interfaces = (); # this represents the areas of each layer to be filled with interface pattern, excluding the contact areas which are stored separately
    my %layers_contact_areas = (); # this represents the areas of each layer having an overhang in the immediately upper layer
    {
        my @current_support_regions = ();   # expolygons we've started to support (i.e. below the empty interface layers)
        my @upper_layers_overhangs = (map [], 1..$Slic3r::Config->support_material_interface_layers);
        for my $i (reverse 0 .. $#{$self->layers}) {
            next unless $Slic3r::Config->support_material
                || ($i <= $Slic3r::Config->raft_layers)  # <= because we need to start from the first non-raft layer
                || ($i <= $Slic3r::Config->support_material_enforce_layers + $Slic3r::Config->raft_layers);
            
            my $layer = $self->layers->[$i];
            my $lower_layer = $i > 0 ? $self->layers->[$i-1] : undef;
            
            my @current_layer_offsetted_slices = map $_->offset_ex($distance_from_object), @{$layer->slices};
            
            # $upper_layers_overhangs[-1] contains the overhangs of the upper layer, regardless of any interface layers
            # $upper_layers_overhangs[0] contains the overhangs of the first upper layer above the interface layers
            
            # we only consider the overhangs of the upper layer to define contact areas of the current one
            $layers_contact_areas{$i} = diff_ex(
                [ map @$_, @{ $upper_layers_overhangs[-1] || [] } ],
                [ map @$_, @current_layer_offsetted_slices ],
            );
            $_->simplify($flow->scaled_spacing) for @{$layers_contact_areas{$i}};
            
            # to define interface regions of this layer we consider the overhangs of all the upper layers
            # minus the first one
            $layers_interfaces{$i} = diff_ex(
                [ map @$_, map @$_, @upper_layers_overhangs[0 .. $#upper_layers_overhangs-1] ],
                [
                    (map @$_, @current_layer_offsetted_slices),
                    (map @$_, @{ $layers_contact_areas{$i} }),
                ],
            );
            $_->simplify($flow->scaled_spacing) for @{$layers_interfaces{$i}};
            
            # generate support material in current layer (for upper layers)
            @current_support_regions = @{diff_ex(
                [
                    (map @$_, @current_support_regions),
                    (map @$_, @{ $upper_layers_overhangs[-1] || [] }),   # only considering -1 instead of the whole array contents is just an optimization
                ],
                [ map @$_, @{$layer->slices} ],
            )};
            shift @upper_layers_overhangs;
            
            $layers{$i} = diff_ex(
                [ map @$_, @current_support_regions ],
                [
                    (map @$_, @current_layer_offsetted_slices),
                    (map @$_, @{ $layers_interfaces{$i} }),
                ],
            );
            $_->simplify($flow->scaled_spacing) for @{$layers{$i}};
            
            # get layer overhangs and put them into queue for adding support inside lower layers;
            # we need an angle threshold for this
            my @overhangs = ();
            if ($lower_layer) {
                # consider all overhangs regardless of their angle if we're told to enforce support on this layer
                my $distance = $i <= ($Slic3r::Config->support_material_enforce_layers + $Slic3r::Config->raft_layers)
                    ? 0
                    : $overhang_width;
                @overhangs = map $_->offset_ex(2 * $distance), @{diff_ex(
                    [ map @$_, map $_->offset_ex(-$distance), @{$layer->slices} ],
                    [ map @$_, @{$lower_layer->slices} ],
                    1,
                )};
            }
            push @upper_layers_overhangs, [@overhangs];
            
            if ($Slic3r::debug) {
                printf "Layer %d (z = %.2f) has %d generic support areas, %d normal interface areas, %d contact areas\n",
                    $i, unscale($layer->print_z), scalar(@{$layers{$i}}), scalar(@{$layers_interfaces{$i}}), scalar(@{$layers_contact_areas{$i}});
            }
        }
    }
    return if !map @$_, values %layers;
    
    # generate paths for the pattern that we're going to use
    Slic3r::debugf "Generating patterns\n";
    my $support_patterns = [];
    my $support_interface_patterns = [];
    {
        # 0.5 ensures the paths don't get clipped externally when applying them to layers
        my @areas = map $_->offset_ex(- 0.5 * $flow->scaled_width),
            @{union_ex([ map $_->contour, map @$_, values %layers ])};
        
        my $pattern = $Slic3r::Config->support_material_pattern;
        my @angles = ($Slic3r::Config->support_material_angle);
        if ($pattern eq 'rectilinear-grid') {
            $pattern = 'rectilinear';
            push @angles, $angles[0] + 90;
        }
        my $filler = Slic3r::Fill->filler($pattern);
        my $make_pattern = sub {
            my ($expolygon, $density) = @_;
            
            my @paths = $filler->fill_surface(
                Slic3r::Surface->new(expolygon => $expolygon),
                density         => $density,
                flow_spacing    => $flow->spacing,
            );
            my $params = shift @paths;
            
            return map Slic3r::ExtrusionPath->new(
                polyline        => Slic3r::Polyline->new(@$_),
                role            => EXTR_ROLE_SUPPORTMATERIAL,
                height          => undef,
                flow_spacing    => $params->{flow_spacing},
            ), @paths;
        };
        foreach my $angle (@angles) {
            $filler->angle($angle);
            {
                my $density = $flow->spacing / $pattern_spacing;
                push @$support_patterns, [ map $make_pattern->($_, $density), @areas ];
            }
            
            if ($Slic3r::Config->support_material_interface_layers > 0) {
                # if pattern is not cross-hatched, rotate the interface pattern by 90° degrees
                $filler->angle($angle + 90) if @angles == 1;
                
                my $spacing = $Slic3r::Config->support_material_interface_spacing;
                my $density = $spacing == 0 ? 1 : $flow->spacing / $spacing;
                push @$support_interface_patterns, [ map $make_pattern->($_, $density), @areas ];
            }
        }
    
        if (0) {
            require "Slic3r/SVG.pm";
            Slic3r::SVG::output("support_$_.svg",
                polylines        => [ map $_->polyline, map @$_, $support_patterns->[$_] ],
                red_polylines    => [ map $_->polyline, map @$_, $support_interface_patterns->[$_] ],
                polygons         => [ map @$_, @areas ],
            ) for 0 .. $#$support_patterns;
        }
    }
    
    # apply the pattern to layers
    Slic3r::debugf "Applying patterns\n";
    {
        my $clip_pattern = sub {
            my ($layer_id, $expolygons, $height, $is_interface) = @_;
            my @paths = ();
            foreach my $expolygon (@$expolygons) {
                push @paths,
                    map $_->pack,
                    map {
                        $_->height($height);
                        
                        # useless line because this coderef isn't called for layer 0 anymore;
                        # let's keep it here just in case we want to make the base flange optional
                        # in the future
                        $_->flow_spacing($self->print->first_layer_support_material_flow->spacing)
                            if $layer_id == 0;
                        
                        $_;
                    }
                    map $_->clip_with_expolygon($expolygon),
                    ###map $_->clip_with_polygon($expolygon->bounding_box_polygon),  # currently disabled as a workaround for Boost failing at being idempotent
                    ($is_interface && @$support_interface_patterns)
                        ? @{$support_interface_patterns->[ $layer_id % @$support_interface_patterns ]}
                        : @{$support_patterns->[ $layer_id % @$support_patterns ]};
            };
            return @paths;
        };
        my %layer_paths             = ();
        my %layer_contact_paths     = ();
        my %layer_islands           = ();
        my $process_layer = sub {
            my ($layer_id) = @_;
            my $layer = $self->layers->[$layer_id];
            
            my ($paths, $contact_paths) = ([], []);
            my $islands = union_ex([ map @$_, map @$_, $layers{$layer_id}, $layers_contact_areas{$layer_id} ]);
            
            # make a solid base on bottom layer
            if ($layer_id == 0) {
                my $filler = Slic3r::Fill->filler('rectilinear');
                $filler->angle($Slic3r::Config->support_material_angle + 90);
                foreach my $expolygon (@$islands) {
                    my @paths = $filler->fill_surface(
                        Slic3r::Surface->new(expolygon => $expolygon),
                        density         => 0.5,
                        flow_spacing    => $self->print->first_layer_support_material_flow->spacing,
                    );
                    my $params = shift @paths;
                    
                    push @$paths, map Slic3r::ExtrusionPath->new(
                        polyline        => Slic3r::Polyline->new(@$_),
                        role            => EXTR_ROLE_SUPPORTMATERIAL,
                        height          => undef,
                        flow_spacing    => $params->{flow_spacing},
                    ), @paths;
                }
            } else {
                $paths           = [
                    $clip_pattern->($layer_id, $layers{$layer_id}, $layer->height),
                    $clip_pattern->($layer_id, $layers_interfaces{$layer_id}, $layer->height, 1),
                ];
                $contact_paths   = [ $clip_pattern->($layer_id, $layers_contact_areas{$layer_id}, $layer->support_material_contact_height, 1) ];
            }
            return ($paths, $contact_paths, $islands);
        };
        Slic3r::parallelize(
            items => [ keys %layers ],
            thread_cb => sub {
                my $q = shift;
                $Slic3r::Geometry::Clipper::clipper = Math::Clipper->new;
                my $result = {};
                while (defined (my $layer_id = $q->dequeue)) {
                    $result->{$layer_id} = [ $process_layer->($layer_id) ];
                }
                return $result;
            },
            collect_cb => sub {
                my $result = shift;
                ($layer_paths{$_}, $layer_contact_paths{$_}, $layer_islands{$_}) = @{$result->{$_}} for keys %$result;
            },
            no_threads_cb => sub {
                ($layer_paths{$_}, $layer_contact_paths{$_}, $layer_islands{$_}) = $process_layer->($_) for keys %layers;
            },
        );
        
        foreach my $layer_id (keys %layer_paths) {
            my $layer = $self->layers->[$layer_id];
            $layer->support_islands($layer_islands{$layer_id});
            $layer->support_fills(Slic3r::ExtrusionPath::Collection->new);
            $layer->support_contact_fills(Slic3r::ExtrusionPath::Collection->new);
            push @{$layer->support_fills->paths}, @{$layer_paths{$layer_id}};
            push @{$layer->support_contact_fills->paths}, @{$layer_contact_paths{$layer_id}};
        }
    }
}

1;
