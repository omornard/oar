package OAR::Nodes;
use strict;
use warnings;
use OAR::Version;
use OAR::IO;
use OAR::Tools;
use OAR::Conf qw(init_conf dump_conf get_conf is_conf);


my $base;

sub open_db_connection(){
	$base  = OAR::IO::connect_ro_one();
        if (defined($base)) { return 1; }
        else {return 0; }
}
sub close_db_connection(){
    OAR::IO::disconnect($base) if (defined($base));
    $base = undef;
}

sub encode_result($$){
    my $result = shift or die("[OAR::Nodes] encode_result: no result to encode");
    my $encoding = shift or die("[OAR::Nodes] encode_result: no format to encode to");
    if($encoding eq "XML"){
        eval "use XML::Dumper qw(pl2xml);1" or die ("No Perl XML module is available");
        my $dump = new XML::Dumper;
        $dump->dtd;
        my $return = $dump->pl2xml($result) or die("XML conversion failed");
        return $return;
    }elsif($encoding eq "YAML"){
        eval "use YAML::Syck;1" or eval "use YAML;1" or die ("No Perl YAML module is available");
        my $return = Dump($result) or die("YAML conversion failed");
        return $return;
    }elsif($encoding eq "JSON"){
        eval "use JSON;1"  or die ("No Perl JSON module is available");
        my $return = JSON->new->pretty(1)->encode($result) or die("JSON conversion failed");
        return $return;
    }
}

sub get_oar_version(){
    return OAR::Version::get_version();
}

sub format_date($){
    my $date = shift;
    return OAR::IO::local_to_sql($date);
}

sub get_all_hosts(){
    my @nodes = OAR::IO::list_nodes($base);
    return \@nodes;
}

sub heartbeat($){
    my $hostname = shift;
    if (OAR::IO::set_node_nextState_if_necessary($base,$hostname,"Alive") > 0){
      my $remote_host = get_conf("SERVER_HOSTNAME");
      my $remote_port = get_conf("SERVER_PORT");
      OAR::Tools::notify_tcp_socket($remote_host,$remote_port,"ChState");
    }
}

sub get_all_resources(){
    my @resources = OAR::IO::list_resources($base);
        return \@resources;
}

sub get_all_resources_opti(){
    my %resources = OAR::IO::get_all_resources($base);
    return \%resources;
}

sub count_all_resources() {
	my $total = OAR::IO::count_all_resources($base);
	return $total;
}

sub get_requested_resources($$){
	my $limit = shift;
	my $offset = shift;
	my @resources = OAR::IO::get_requested_resources($base,$limit,$offset);
	return \@resources;
}

sub get_events($$){
	my $hostname = shift;
	my $date_from = shift;
	my @events = OAR::IO::get_events_for_hostname($base, $hostname, $date_from);
	return \@events;
}

sub get_resources_with_given_sql($){
	my $sql_clause = shift;
	my @sql_resources = OAR::IO::get_resources_with_given_sql($base,$sql_clause);
	return \@sql_resources;
}

sub get_nodes_with_given_sql($){
	my $sql_clause = shift;
	my @sql_resources = OAR::IO::get_nodes_with_given_sql($base,$sql_clause);
	return \@sql_resources;
}

sub get_resources_states($){
	my $resources = shift;
	my %resources_states;
	foreach my $current_resource (@$resources){
		my $properties = OAR::IO::get_resource_info($base, $current_resource);
                if ($properties->{state} eq "Absent" && $properties->{available_upto} >= time()) {
                   $properties->{state} .= " (standby)";
                }
		$resources_states{$current_resource} = $properties->{state};
	}
	return \%resources_states;
}

sub get_resources_states_for_host($){
	my $hostname = shift;
	my @node_info = OAR::IO::get_node_info($base, $hostname);
	my @resources;
	foreach my $info (@node_info){
		push @resources, $info->{resource_id};
	}
	return get_resources_states(\@resources);
}

sub get_resource_infos($){
  my $id=shift;
  my $resource = OAR::IO::get_resource_info($base,$id);
}

sub is_job_tokill($){
  my $id=shift;
  return OAR::IO::is_tokill_job($base,$id);
}

sub get_resources_infos($){
	my $resources = shift;
	my %resources_infos;
	foreach my $current_resource (@$resources){
		my $properties = OAR::IO::get_resource_info($base, $current_resource);
		add_running_jobs_to_resource_properties($properties);
		$resources_infos{$current_resource} = $properties
	}
	return \%resources_infos;
}

sub get_resources_for_host($){
	my $hostname = shift;
	my @resources = OAR::IO::get_node_info($base, $hostname);
        return \@resources;
}

sub get_resources_infos_for_host($){
	my $hostname = shift;
	my @node_info = OAR::IO::get_node_info($base, $hostname);
	my @resources;
	foreach my $info (@node_info){
		push @resources, $info->{resource_id};
	}
	return get_resources_infos(\@resources);
}

sub get_jobs_running_on_resource($){
	my $resource_id = shift;
	my @jobs = OAR::IO::get_resource_job($base, $resource_id);
	return \@jobs;
}

sub get_jobs_running_on_node($){
        my $node = shift;
        my @node_info = OAR::IO::get_node_info($base, $node);
        my @jobs;
        foreach my $info (@node_info){
          my @resource_jobs = OAR::IO::get_resource_job($base, $info->{resource_id});
          foreach my $job (@resource_jobs) {
            push(@jobs,$job);
          }
        }
    return \@jobs;
}

sub get_jobs_on_node($$){
        my $node = shift;
        my $state = shift;
        my @node_info = OAR::IO::get_node_info($base, $node);
        my @jobs;
        foreach my $info (@node_info){
          my @resource_jobs = OAR::IO::get_resource_job_with_state($base, $info->{resource_id},$state);
          foreach my $job (@resource_jobs) {
            push(@jobs,$job);
          }
        }
    return \@jobs;
}

sub add_running_jobs_to_resource_properties($){
	my $info = shift;
	if ($info->{state} eq "Alive"){
		my $jobs = get_jobs_running_on_resource($info->{resource_id});
		if (@$jobs > 0){
# 			my $jobs_string = Dumper($jobs); # not proud of it...
# 			$jobs = join(', ', split(/,/, $jobs_string));
# 			$jobs =~ s/[\[\]\']//g;
			my $jobs_string = '';
			foreach my $current_job (@$jobs){
				$jobs_string .= $current_job.", ";
			}
			chop($jobs_string); # remove last space
			chop($jobs_string); # remove last ,
			$info->{jobs} = $jobs_string;
		}
	}
}

sub get_all_resources_jobs() {
	my $res;

	$res = OAR::IO::get_resources_jobs($base);

	return $res;
}
1;
