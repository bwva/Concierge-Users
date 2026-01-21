package Concierge::Users::YAML v0.7.0;
use v5.40;
use Carp qw/ croak /;
use YAML;
use File::Path qw/ make_path /;
use File::Spec;
use parent qw/ Concierge::Users::Meta /;

# ABSTRACT: YAML file backend for Concierge::Users

# ==============================================================================
# Configure Class Method - One-time setup (called by Users->setup)
# ==============================================================================

sub configure {
    my ($class, $setup_config) = @_;

    # Extract storage_dir
    my $storage_dir = $setup_config->{storage_dir};

    # For YAML backend, storage is just the directory
    # No additional setup needed beyond ensuring storage_dir exists
    # (already done by Users->setup before calling configure)

    # Create temporary object for archiving
    my $temp_backend = bless {
        storage_dir => $storage_dir,
        fields      => $setup_config->{fields} || [],
        field_definitions => $setup_config->{field_definitions},
    }, $class;

    # Check for existing YAML files and archive if present
    if (opendir(my $dh, $storage_dir)) {
        my @yaml_files = grep { /\.yaml$/ && -f "$storage_dir/$_" } readdir $dh;
        closedir $dh;

        # Archive if YAML files exist
        if (@yaml_files) {
            my $archive_result = $temp_backend->_archive_user_data();
            unless ($archive_result->{success}) {
                return {
                    success => 0,
                    message => $archive_result->{message},
                };
            }
        }
    }

    # Return success with config
    return {
        success => 1,
        message => "YAML backend configured successfully",
        config => {
            storage_dir       => $storage_dir,
            fields            => $setup_config->{fields} || [],
            field_definitions => $setup_config->{field_definitions},
        },
    };
}

# ==============================================================================
# Constructor - Runtime instantiation (called by Users->new)
# ==============================================================================

sub new {
    my ($class, $runtime_config) = @_;

    # Extract parameters from saved config (no validation needed)
    my $storage_dir = $runtime_config->{storage_dir};

    return bless {
        storage_dir      => $storage_dir,
        fields           => $runtime_config->{fields} || [],
        field_definitions => $runtime_config->{field_definitions} || {},
    }, $class;
}

# Report backend configuration (for debugging/info)
sub config {
    my ($self) = @_;

    return {
        storage_dir       => $self->{storage_dir},
        fields	       	  => $self->{fields},
        field_definitions => $self->{field_definitions},
    };
}

# Get user file path
sub _get_user_file {
    my ($self, $user_id) = @_;

    return File::Spec->catfile($self->{storage_dir}, "$user_id.yaml");
}

# Archive existing user data (internal method, called by configure)
sub _archive_user_data {
    my ($self) = @_;

    # Generate timestamp for archive directory name
    my $timestamp = $self->archive_timestamp();
    my $archive_dir = "$self->{storage_dir}/users_$timestamp";

    # Create archive directory
    unless (mkdir $archive_dir) {
        return {
            success => 0,
            message => "Failed to create archive directory: $!"
        };
    }

    # Find and move all .yaml files
    my $dh;
    unless (opendir($dh, $self->{storage_dir})) {
        return {
            success => 0,
            message => "Failed to open storage directory: $!"
        };
    }

    my @yaml_files = grep { /\.yaml$/ && -f "$self->{storage_dir}/$_" } readdir $dh;
    closedir $dh;

    foreach my $file (@yaml_files) {
        my $old_path = "$self->{storage_dir}/$file";
        my $new_path = "$archive_dir/$file";

        unless (rename $old_path, $new_path) {
            return {
                success => 0,
                message => "Failed to archive YAML file '$file': $!"
            };
        }
    }

    return { success => 1 };
}

# Add bare record with user_id, moniker, defaults, and null_values from Users.pm
sub add {
    my ($self, $user_id, $initial_record) = @_;
    return { success => 0, message => "Add Record failed: missing user_id" }
    	unless $user_id;
    return { success => 0, message => "Add Record failed: missing initial record" }
    	unless $initial_record;

	my %record				= $initial_record->%*;
	$record{created_date}	= $self->current_timestamp();
	# Add last_mod_date timestamp
    $record{last_mod_date} = $self->current_timestamp();

    my $user_file = $self->_get_user_file($user_id);

    eval {
        YAML::DumpFile($user_file, \%record);
    };

    if ($@) {
        return { success => 0, message => "Failed to create initial user record: $@" };
    }

    return { success => 1, message => "Initial record created for user '$user_id'" };
}

# Fetch user by ID
sub fetch {
    my ($self, $user_id) = @_;

    my $user_file = $self->_get_user_file($user_id);

    return {
        success => 0,
        data => '',
        message => "User '$user_id' not found"
    } unless -f $user_file;

    my $user_data;
    eval {
        $user_data = YAML::LoadFile($user_file);
    };

    if ($@) {
        return {
            success => 0,
            data => '',
            message => "Failed to load user data: $@"
        };
    }

    return {
        success => 1,
        data => $user_data,
        message => ''
    };
}

# Update user
sub update {
    my ($self, $user_id, $updates) = @_;

    # Remove readonly fields from updates
    my %readonly = map { $_ => 1 } qw(user_id created_date last_mod_date);
    delete $updates->{$_} for keys %readonly;

    # Add last_mod_date timestamp
    $updates->{last_mod_date} = $self->current_timestamp();

    my $user_file = $self->_get_user_file($user_id);

    return { success => 0, message => "User '$user_id' not found" } unless -f $user_file;

    # Load existing data
    my $user_data;
    eval {
        $user_data = YAML::LoadFile($user_file);
    };

    return { success => 0, message => "Failed to load user data: $@" } if $@;

    # Apply updates
    foreach my $field (keys %$updates) {
        $user_data->{$field} = $updates->{$field};
    }

    # Save back
    eval {
        YAML::DumpFile($user_file, $user_data);
    };

    if ($@) {
        return { success => 0, message => "Failed to update user file: $@" };
    }

    return { success => 1, message => "User '$user_id' updated" };
}

# List users with filters
sub list {
    my ($self, $filters, $options) = @_;

    # Read all YAML files
    opendir my $dh, $self->{storage_dir} or return { data => [], total_count => 0 };
    my @files = grep { /\.yaml$/ } readdir $dh;
    closedir $dh;

    my @users;
    foreach my $file (@files) {
        my $user_file = File::Spec->catfile($self->{storage_dir}, $file);
        my $user_data;

        eval {
            $user_data = YAML::LoadFile($user_file);
        };

        next if $@;

        # Apply DSL filters
        my $match = 1;

        if (ref $filters eq 'HASH' && exists $filters->{or_groups}) {
            $match = 0;  # Start with no match, need at least one OR group to match

            foreach my $and_group (@{$filters->{or_groups}}) {
                my $group_match = 1;  # All conditions in this AND group must match

                foreach my $condition (@$and_group) {
                    my ($field, $op, $value) = ($condition->{field}, $condition->{op}, $condition->{value});
                    my $user_value = $user_data->{$field} || '';

                    if ($op eq '=') {
                        $group_match = 0 unless $user_value eq $value;
                    } elsif ($op eq ':') {
                        $group_match = 0 unless $user_value =~ /\Q$value\E/i;
                    } elsif ($op eq '!') {
                        $group_match = 0 if $user_value =~ /\Q$value\E/i;
                    } elsif ($op eq '>') {
                        $group_match = 0 unless $user_value gt $value;
                    } elsif ($op eq '<') {
                        $group_match = 0 unless $user_value lt $value;
                    }
                }

                $match = 1 if $group_match;  # At least one OR group matched
                last if $match;
            }
        }

        push @users, $user_data if $match;
    }

    return {
        data => \@users,
        total_count => scalar @users,
    };
}

# Delete user
sub delete {
    my ($self, $user_id) = @_;

    my $user_file = $self->_get_user_file($user_id);

    return { success => 0, message => "User '$user_id' not found" } unless -f $user_file;

    unlink $user_file or return { success => 0, message => "Failed to delete user file: $!" };

    return { success => 1, message => "User '$user_id' deleted" };
}

# Cleanup
sub disconnect {
    my $self = shift;
    # No resources to clean up for YAML backend
}

1;

__END__
