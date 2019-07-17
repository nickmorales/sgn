package CXGN::Image::Search;

=head1 NAME

CXGN::Image::Search - an object to handle searching for images given criteria

=head1 USAGE

my $image_search = CXGN::Image::Search->new({
    bcs_schema=>$schema,
});
my ($result, $total_count) = $image_search->search();

=head1 DESCRIPTION


=head1 AUTHORS


=cut

use strict;
use warnings;
use Moose;
use Try::Tiny;
use Data::Dumper;
use SGN::Model::Cvterm;
use JSON;

has 'bcs_schema' => ( isa => 'Bio::Chado::Schema',
    is => 'rw',
    required => 1,
);

has 'image_id_list' => (
    isa => 'ArrayRef[Int]|Undef',
    is => 'rw',
);

has 'image_names_exact' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'image_name_list' => (
    isa => 'ArrayRef[Str]|Undef',
    is => 'rw',
);

has 'include_obsolete_images' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'original_filenames_exact' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'original_filename_list' => (
    isa => 'ArrayRef[Str]|Undef',
    is => 'rw',
);

has 'descriptions_exact' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'description_list' => (
    isa => 'ArrayRef[Str]|Undef',
    is => 'rw',
);

has 'tag_list_exact' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'tag_list' => (
    isa => 'ArrayRef[Str]|Undef',
    is => 'rw',
);

has 'include_obsolete_tags' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'include_obsolete_image_tags' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'submitter_usernames_exact' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'submitter_username_list' => (
    isa => 'ArrayRef[Str]|Undef',
    is => 'rw',
);

has 'submitter_first_names_exact' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'submitter_first_name_list' => (
    isa => 'ArrayRef[Str]|Undef',
    is => 'rw',
);

has 'submitter_last_names_exact' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'submitter_last_name_list' => (
    isa => 'ArrayRef[Str]|Undef',
    is => 'rw',
);

has 'submitter_id_list' => (
    isa => 'ArrayRef[Int]|Undef',
    is => 'rw',
);

has 'stock_type' => (
    isa => 'Str|Undef',
    is => 'rw',
);

has 'stock_id_list' => (
    isa => 'ArrayRef[Int]|Undef',
    is => 'rw',
);

has 'stock_names_exact' => (
    isa => 'Bool|Undef',
    is => 'rw',
    default => 0
);

has 'stock_name_list' => (
    isa => 'ArrayRef[Str]|Undef',
    is => 'rw',
);

# has 'project_id_list' => (
#     isa => 'ArrayRef[Int]|Undef',
#     is => 'rw',
# );
# 
# has 'project_names_exact' => (
#     isa => 'Bool|Undef',
#     is => 'rw',
#     default => 0
# );
# 
# has 'project_name_list' => (
#     isa => 'ArrayRef[Str]|Undef',
#     is => 'rw',
# );

has 'limit' => (
    isa => 'Int|Undef',
    is => 'rw'
);

has 'offset' => (
    isa => 'Int|Undef',
    is => 'rw'
);

sub search {
    my $self = shift;
    my $schema = $self->bcs_schema();
    my $image_id_list = $self->image_id_list;
    my $image_name_list = $self->image_name_list;
    my $image_names_exact = $self->image_names_exact;
    my $original_filename_list = $self->original_filename_list;
    my $original_filenames_exact = $self->original_filenames_exact;
    my $description_list = $self->description_list;
    my $descriptions_exact = $self->descriptions_exact;
    my $tag_list = $self->tag_list;
    my $tag_list_exact = $self->tag_list_exact;
    my $submitter_username_list = $self->submitter_username_list;
    my $submitter_usernames_exact = $self->submitter_usernames_exact;
    my $submitter_first_name_list = $self->submitter_first_name_list;
    my $submitter_first_names_exact = $self->submitter_first_names_exact;
    my $submitter_last_name_list = $self->submitter_last_name_list;
    my $submitter_last_names_exact = $self->submitter_last_names_exact;
    my $submitter_id_list = $self->submitter_id_list;
    my $stock_type = $self->stock_type;
    my $stock_id_list = $self->stock_id_list;
    my $stock_name_list = $self->stock_name_list;
    my $stock_names_exact = $self->stock_names_exact;
    # my $project_id_list = $self->project_id_list;
    # my $project_name_list = $self->project_name_list;
    # my $project_names_exact = $self->project_names_exact;
    my $include_obsolete_images = $self->include_obsolete_images;
    my $include_obsolete_tags = $self->include_obsolete_tags;
    my $include_obsolete_image_tags = $self->include_obsolete_image_tags;

    my @where_clause;
    my @or_clause;

    if ($stock_type){
        my $stock_type_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, $stock_type, 'stock_type')->cvterm_id();
        push @where_clause, "stock.type_id = $stock_type_cvterm_id";
    }

    if ($image_id_list && scalar(@$image_id_list)>0) {
        my $sql = join ("," , @$image_id_list);
        push @where_clause, "image.image_id in ($sql)";
    }
    if ($image_name_list && scalar(@$image_name_list)>0) {
        if ($image_names_exact) {
            my $sql = join ("','" , @$image_name_list);
            my $name_sql = "'" . $sql . "'";
            push @where_clause, "image.name in ($name_sql)";
        } else {
            foreach (@$image_name_list) {
                push @or_clause, "image.name ilike '%".$_."%'";
            }
        }
    }
    if ($original_filename_list && scalar(@$original_filename_list)>0) {
        if ($original_filenames_exact) {
            my $sql = join ("','" , @$original_filename_list);
            my $name_sql = "'" . $sql . "'";
            push @where_clause, "image.original_filename in ($name_sql)";
        } else {
            foreach (@$original_filename_list) {
                push @or_clause, "image.original_filename ilike '%".$_."%'";
            }
        }
    }
    if ($description_list && scalar(@$description_list)>0) {
        if ($descriptions_exact) {
            my $sql = join ("','" , @$description_list);
            my $name_sql = "'" . $sql . "'";
            push @where_clause, "image.description in ($name_sql)";
        } else {
            foreach (@$description_list) {
                push @or_clause, "image.description ilike '%".$_."%'";
            }
        }
    }
    if ($tag_list && scalar(@$tag_list)>0) {
        if ($tag_list_exact) {
            my $sql = join ("','" , @$tag_list);
            my $name_sql = "'" . $sql . "'";
            push @where_clause, "tags.name in ($name_sql)";
        } else {
            foreach (@$tag_list) {
                push @or_clause, "tags.name ilike '%".$_."%'";
            }
        }
        if (!$include_obsolete_tags) {
            push @where_clause, "image_tag.obsolete = 'f'";
        }
        if (!$include_obsolete_image_tags) {
            push @where_clause, "tags.obsolete = 'f'";
        }
    }
    if ($submitter_username_list && scalar(@$submitter_username_list)>0) {
        if ($submitter_usernames_exact) {
            my $sql = join ("','" , @$submitter_username_list);
            my $name_sql = "'" . $sql . "'";
            push @where_clause, "submitter.username in ($name_sql)";
        } else {
            foreach (@$submitter_username_list) {
                push @or_clause, "submitter.username ilike '%".$_."%'";
            }
        }
    }
    if ($submitter_first_name_list && scalar(@$submitter_first_name_list)>0) {
        if ($submitter_first_names_exact) {
            my $sql = join ("','" , @$submitter_first_name_list);
            my $name_sql = "'" . $sql . "'";
            push @where_clause, "submitter.first_name in ($name_sql)";
        } else {
            foreach (@$submitter_first_name_list) {
                push @or_clause, "submitter.first_name ilike '%".$_."%'";
            }
        }
    }
    if ($submitter_last_name_list && scalar(@$submitter_last_name_list)>0) {
        if ($submitter_last_names_exact) {
            my $sql = join ("','" , @$submitter_last_name_list);
            my $name_sql = "'" . $sql . "'";
            push @where_clause, "submitter.last_name in ($name_sql)";
        } else {
            foreach (@$submitter_last_name_list) {
                push @or_clause, "submitter.last_name ilike '%".$_."%'";
            }
        }
    }
    if ($submitter_id_list && scalar(@$submitter_id_list)>0) {
        my $sql = join ("," , @$submitter_id_list);
        push @where_clause, "submitter.sp_person_id in ($sql)";
    }
    if ($stock_id_list && scalar(@$stock_id_list)>0) {
        my $sql = join ("," , @$stock_id_list);
        push @where_clause, "stock.stock_id in ($sql)";
    }
    if ($stock_name_list && scalar(@$stock_name_list)>0) {
        if ($stock_names_exact) {
            my $sql = join ("','" , @$stock_name_list);
            my $name_sql = "'" . $sql . "'";
            push @where_clause, "stock.uniquename in ($name_sql)";
        } else {
            foreach (@$stock_name_list) {
                push @or_clause, "stock.uniquename ilike '%".$_."%'";
            }
        }
    }
    # if ($project_id_list && scalar(@$project_id_list)>0) {
    #     my $sql = join ("," , @$project_id_list);
    #     push @where_clause, "project.project_id in ($sql)";
    # }
    # if ($project_name_list && scalar(@$project_name_list)>0) {
    #     if ($project_names_exact) {
    #         my $sql = join ("','" , @$project_name_list);
    #         my $name_sql = "'" . $sql . "'";
    #         push @where_clause, "project.name in ($name_sql)";
    #     } else {
    #         foreach (@$project_name_list) {
    #             push @or_clause, "project.name ilike '%".$_."%'";
    #         }
    #     }
    # }
    if (!$include_obsolete_images) {
        push @where_clause, "image.obsolete = 'f'";
    }

    if (scalar(@or_clause)>0) {
        my $w = " ( ".(join (" OR ", @or_clause) )." ) ";
        push @where_clause, $w;
    }
    my $where_clause = scalar(@where_clause)>0 ? " WHERE " . (join (" AND " , @where_clause)) : '';

    my $offset_clause = '';
    my $limit_clause = '';
    if ($self->limit){
        $limit_clause = " LIMIT ".$self->limit;
    }
    if ($self->offset){
        $offset_clause = " OFFSET ".$self->offset;
    }

    my $q = "SELECT image.image_id, image.name, image.description, image.original_filename, image.file_ext, image.sp_person_id, submitter.username, image.create_date, image.modified_date, image.obsolete, image.md5sum, stock.stock_id, stock.uniquename, stock_type.name, 
    COALESCE(
        json_agg(json_build_object('tag_id', tags.tag_id, 'name', tags.name, 'description', tags.description, 'sp_person_id', tags.sp_person_id, 'modified_date', tags.modified_date, 'create_date', tags.create_date, 'obsolete', tags.obsolete))
        FILTER (WHERE tags.tag_id IS NOT NULL), '[]'
    ) AS tags,
    count(image.image_id) OVER() AS full_count
        FROM metadata.md_image AS image
        JOIN sgn_people.sp_person AS submitter ON (submitter.sp_person_id=image.sp_person_id)
        LEFT JOIN metadata.md_tag_image AS image_tag ON (image.image_id=image_tag.image_id)
        LEFT JOIN metadata.md_tag AS tags ON (image_tag.tag_id=tags.tag_id)
        LEFT JOIN phenome.stock_image AS stock_image ON (image.image_id=stock_image.image_id)
        LEFT JOIN stock ON (stock_image.stock_id=stock.stock_id)
        LEFT JOIN cvterm AS stock_type ON (stock.type_id=stock_type.cvterm_id)
        $where_clause
        GROUP BY(image.image_id, image.name, image.description, image.original_filename, image.file_ext, image.sp_person_id, submitter.username, image.create_date, image.modified_date, image.obsolete, image.md5sum, stock.stock_id, stock.uniquename, stock_type.name)
        ORDER BY image.image_id
        $limit_clause
        $offset_clause;";

    print STDERR Dumper $q;
    my $h = $schema->storage->dbh()->prepare($q);
    $h->execute();

    my @result;
    my $total_count = 0;
    while (my ($image_id, $image_name, $image_description, $image_original_filename, $image_file_ext, $image_sp_person_id, $image_username, $image_create_date, $image_modified_date, $image_obsolete, $image_md5sum, $stock_id, $stock_uniquename, $stock_type_name, $tags, $full_count) = $h->fetchrow_array()) {
        push @result, {
            image_id => $image_id,
            image_name => $image_name,
            image_description => $image_description,
            image_original_filename => $image_original_filename,
            image_file_ext => $image_file_ext,
            image_sp_person_id => $image_sp_person_id,
            image_username => $image_username,
            image_create_date => $image_create_date,
            image_modified_date => $image_modified_date,
            image_obsolete => $image_obsolete,
            image_md5sum => $image_md5sum,
            stock_id => $stock_id,
            stock_uniquename => $stock_uniquename,
            stock_type_name => $stock_type_name,
            tags_array => decode_json $tags
        };
        $total_count = $full_count;
    }
    #print STDERR Dumper \@result;
    return (\@result, $total_count);
}

1;
