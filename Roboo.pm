# Roboo - HTTP Robot Mitigator
# Copyright (C) 2011 Yuri Gushin, Alex Behar
#
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA


package Roboo;
our $VERSION = '0.60';

use nginx;
use warnings;
use strict;
use Digest::SHA qw(sha1_hex);
use Net::IP::Match::Regexp qw(create_iprange_regexp match_ip);
use Crypt::Random qw(makerandom_octet);
use Compress::Zlib qw{compress};

my $settings = {};
my $valid_cookie;

sub handler ($) {
    my $request = shift;

    # Initialize
    init($request);

    # Proxy whitelisted IP addresses and User-Agents
    if (whitelisted_network($request) or whitelisted_useragent($request)) {
        return 555;
    }

    # Generate cookie
    $valid_cookie = generate_cookie($settings->{challenge_hash_input}, get_secret());
    
    # Proxy clients with valid cookies if exist
    if (valid_cookie($request)) {
        return 555;
    }
    
    # Cookie isn't valid or doesn't exist - begin challenge/response
    if ($request->request_method eq 'GET') { 
        challenge_GET($request);
    } elsif ($request->request_method eq 'POST') {
        if ($request->has_request_body(\&challenge_POST)) {
            return OK;
        }
        return HTTP_BAD_REQUEST;
    }
}

# check if client IP is whitelisted
sub whitelisted_network ($) {
    my $request = shift;
    
    return (defined $settings->{whitelisted_networks} && match_ip($request->remote_addr, $settings->{whitelisted_networks}));    
}

# check if client User-Agent value is whitelisted
sub whitelisted_useragent ($) {
    my $request = shift;

    if (defined $settings->{whitelisted_useragents} && defined $request->header_in('User-Agent')) {
        foreach my $UA (@{$settings->{whitelisted_useragents}}) {
            if (index($request->header_in('User-Agent'), $UA) != -1) {
                return 1;
            }
        }
    }
    return 0;
}

# check if client cookie is valid
sub valid_cookie ($) {
    my $request = shift;

    return (defined($request->header_in('Cookie')) && $request->header_in('Cookie') =~ "$settings->{cookie_name}=$valid_cookie");
}

# Initialize Roboo settings and generate secret key
sub init ($) {
    my $request = shift;
    
    if (not %{$settings}) {
        # Populate settings from Nginx configuration
        $settings->{cookie_name} = $request->variable('Roboo_cookie_name') ? $request->variable('Roboo_cookie_name') : 'Anti-Robot';
        $settings->{validity_window} = $request->variable('Roboo_validity_window') ? $request->variable('Roboo_validity_window') : 600;
        $settings->{challenge_modes} = $request->variable('Roboo_challenge_modes') ? $request->variable('Roboo_challenge_modes') : 'SWF';
        $settings->{challenge_hash_input} = $request->variable('Roboo_challenge_hash_input') ? $request->variable('Roboo_challenge_hash_input') : $request->remote_addr;
        $settings->{whitelist} = $request->variable('Roboo_whitelist') ? $request->variable('Roboo_whitelist') : '';
        
        # Generate whitelist arrays
        if ($settings->{whitelist} ne '') {
            my @whitelisted_networks = ($settings->{whitelist} =~ /IP\(([^)]+)\)/g);
            $settings->{whitelisted_networks} = create_iprange_regexp(@whitelisted_networks) unless (not scalar @whitelisted_networks);
            @{$settings->{whitelisted_useragents}} = ($settings->{whitelist} =~ /UA\('([^']+)'\)/g);
        }
        # Get RANDBITS for get_timeseed
        use Config;
        $settings->{internal_randbits} = $Config{randbits};
        no Config;
        # Get master process id
        $settings->{internal_masterpid} = getppid();
        # Generate/synchronize random secret
        $settings->{internal_secret} = generate_secret();
    }
}

# Challenge cookie value is a time-based SHA1 hash of - secret, client IP, and optionally Host & User-Agent header values
sub generate_cookie (@) {
    return sha1_hex(@_, get_timeseed());
}

sub generate_secret () {
    use IPC::SysV qw(IPC_CREAT);
    use IPC::SharedMem;

    my $shared = IPC::SharedMem->new(13373, 128, IPC_CREAT | 0600) or die "Cannot interface with shared memory: $_";
    $shared->attach;

    if ($shared->read(0,128) !~ /^$settings->{internal_masterpid}:/s) {
        my $secret = makerandom_octet(Length => 64, Strength => 1);
        $shared->write("$settings->{internal_masterpid}:$secret",0,128);
    }

    no IPC::SysV qw(IPC_CREAT);
    no IPC::SharedMem;

    return $shared;
}

sub get_secret ($) {
    $settings->{internal_secret}->read(0,128) =~ /^$settings->{internal_masterpid}:(.{64})/s;

    return $1;
}

sub get_timeseed () {
    my $valid_time = time();

    $valid_time = $valid_time - ($valid_time % $settings->{validity_window});
    srand($valid_time);

    return int(rand(2**$settings->{internal_randbits}-1));
}

# respond with a challenge for GET requests, triggering an automatic reload of the page 
sub challenge_GET ($) {
    my $request = shift;

    if ($settings->{challenge_modes} =~ 'SWF') {
        challenge_GET_SWF($request);
    } else {
        challenge_GET_JS($request);
    }
}

sub challenge_GET_JS ($) {
    my $request = shift;
    my $response = <<EOF;
<html>
<body onload="challenge();">
<script>
eval(function(p,a,c,k,e,r){e=function(c){return c.toString(a)};if(!''.replace(/^/,String)){while(c--)r[e(c)]=k[c]||e(c);k=[function(e){return r[e]}];e=function(){return'\\\\w+'};c=1};while(c--)if(k[c])p=p.replace(new RegExp('\\\\b'+e(c)+'\\\\b','g'),k[c]);return p}('1 6(){2.3=\\'4=5; 0-7=8; 9=/\\';a.b.c()}',13,13,'max|function|document|cookie|$settings->{cookie_name}|$valid_cookie|challenge|age|$settings->{validity_window}|path|window|location|reload'.split('|'),0,{}))
</script>
</body>
</html>
EOF

    $request->send_http_header('text/html');
    $request->print($response);
    $request->rflush;
    return OK; 
}

sub challenge_GET_SWF ($) {
    my $request = shift;
    my $response;
    my $cookie_snip = substr($valid_cookie,20);

    # POST SWF challenges will trigger a GET for the .swf file - below we make sure to send the correct response
    if ($request->uri =~ /\/$settings->{cookie_name}-(?:POST|GET)-$cookie_snip.swf$/) {
        if ($request->uri =~ /-GET-/) {
            $response = "\x0a\xf3\x05\x00\x00\x60\x00\x3e\x80\x00\x3e\x80\x00\x1e\x01\x00\x44\x11\x18\x00\x00\x00\x7f\x13\xcb\x01\x00\x00\x3c\x72\x64\x66\x3a\x52\x44\x46\x20\x78\x6d\x6c\x6e\x73\x3a\x72\x64\x66\x3d\x27\x68\x74\x74\x70\x3a\x2f\x2f\x77\x77\x77\x2e\x77\x33\x2e\x6f\x72\x67\x2f\x31\x39\x39\x39\x2f\x30\x32\x2f\x32\x32\x2d\x72\x64\x66\x2d\x73\x79\x6e\x74\x61\x78\x2d\x6e\x73\x23\x27\x3e\x3c\x72\x64\x66\x3a\x44\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x20\x72\x64\x66\x3a\x61\x62\x6f\x75\x74\x3d\x27\x27\x20\x78\x6d\x6c\x6e\x73\x3a\x64\x63\x3d\x27\x68\x74\x74\x70\x3a\x2f\x2f\x70\x75\x72\x6c\x2e\x6f\x72\x67\x2f\x64\x63\x2f\x65\x6c\x65\x6d\x65\x6e\x74\x73\x2f\x31\x2e\x31\x27\x3e\x3c\x64\x63\x3a\x66\x6f\x72\x6d\x61\x74\x3e\x61\x70\x70\x6c\x69\x63\x61\x74\x69\x6f\x6e\x2f\x78\x2d\x73\x68\x6f\x63\x6b\x77\x61\x76\x65\x2d\x66\x6c\x61\x73\x68\x3c\x2f\x64\x63\x3a\x66\x6f\x72\x6d\x61\x74\x3e\x3c\x64\x63\x3a\x74\x69\x74\x6c\x65\x3e\x41\x64\x6f\x62\x65\x20\x46\x6c\x65\x78\x20\x34\x20\x41\x70\x70\x6c\x69\x63\x61\x74\x69\x6f\x6e\x3c\x2f\x64\x63\x3a\x74\x69\x74\x6c\x65\x3e\x3c\x64\x63\x3a\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x3e\x68\x74\x74\x70\x3a\x2f\x2f\x77\x77\x77\x2e\x61\x64\x6f\x62\x65\x2e\x63\x6f\x6d\x2f\x70\x72\x6f\x64\x75\x63\x74\x73\x2f\x66\x6c\x65\x78\x3c\x2f\x64\x63\x3a\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x3e\x3c\x64\x63\x3a\x70\x75\x62\x6c\x69\x73\x68\x65\x72\x3e\x75\x6e\x6b\x6e\x6f\x77\x6e\x3c\x2f\x64\x63\x3a\x70\x75\x62\x6c\x69\x73\x68\x65\x72\x3e\x3c\x64\x63\x3a\x63\x72\x65\x61\x74\x6f\x72\x3e\x75\x6e\x6b\x6e\x6f\x77\x6e\x3c\x2f\x64\x63\x3a\x63\x72\x65\x61\x74\x6f\x72\x3e\x3c\x64\x63\x3a\x6c\x61\x6e\x67\x75\x61\x67\x65\x3e\x45\x4e\x3c\x2f\x64\x63\x3a\x6c\x61\x6e\x67\x75\x61\x67\x65\x3e\x3c\x64\x63\x3a\x64\x61\x74\x65\x3e\x46\x65\x62\x20\x31\x32\x2c\x20\x32\x30\x31\x31\x3c\x2f\x64\x63\x3a\x64\x61\x74\x65\x3e\x3c\x2f\x72\x64\x66\x3a\x44\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x3e\x3c\x2f\x72\x64\x66\x3a\x52\x44\x46\x3e\x00\x44\x10\xe8\x03\x3c\x00\x43\x02\xff\xff\xff\x5a\x0a\x03\x00\x00\x00\x06\x00\x00\x00\x04\x00\x4f\x37\x00\x00\x00\x00\x00\x00\x1d\xf7\x17\x1b\x2e\x01\x00\x00\xc4\x0a\x47\x45\x54\x00\xbf\x14\xc8\x03\x00\x00\x01\x00\x00\x00\x66\x72\x61\x6d\x65\x31\x00\x10\x00\x2e\x00\x00\x00\x00\x1e\x00\x04\x76\x6f\x69\x64\x0c\x66\x6c\x61\x73\x68\x2e\x65\x76\x65\x6e\x74\x73\x05\x45\x76\x65\x6e\x74\x03\x47\x45\x54\x0d\x66\x6c\x61\x73\x68\x2e\x64\x69\x73\x70\x6c\x61\x79\x06\x53\x70\x72\x69\x74\x65\x0b\x43\x4f\x4f\x4b\x49\x45\x5f\x4e\x41\x4d\x45\x06\x53\x74\x72\x69\x6e\x67\x28\x52\x6f\x62\x6f\x6f\x5f\x6e\x61\x6d\x65\x5f\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x50\x4c\x41\x43\x45\x48\x4f\x4c\x44\x45\x52\x0c\x43\x4f\x4f\x4b\x49\x45\x5f\x56\x41\x4c\x55\x45\x28\x52\x6f\x62\x6f\x6f\x5f\x76\x61\x6c\x75\x65\x5f\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x50\x4c\x41\x43\x45\x48\x4f\x4c\x44\x45\x52\x0f\x43\x4f\x4f\x4b\x49\x45\x5f\x56\x41\x4c\x49\x44\x49\x54\x59\x28\x52\x6f\x62\x6f\x6f\x5f\x76\x61\x6c\x69\x64\x69\x74\x79\x5f\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x50\x4c\x41\x43\x45\x48\x4f\x4c\x44\x45\x52\x04\x69\x6e\x69\x74\x05\x73\x74\x61\x67\x65\x10\x61\x64\x64\x45\x76\x65\x6e\x74\x4c\x69\x73\x74\x65\x6e\x65\x72\x0e\x41\x44\x44\x45\x44\x5f\x54\x4f\x5f\x53\x54\x41\x47\x45\x13\x72\x65\x6d\x6f\x76\x65\x45\x76\x65\x6e\x74\x4c\x69\x73\x74\x65\x6e\x65\x72\x03\x58\x4d\x4c\x86\x02\x3c\x73\x63\x72\x69\x70\x74\x3e\x0d\x0a\x09\x09\x09\x09\x09\x3c\x21\x5b\x43\x44\x41\x54\x41\x5b\x0d\x0a\x09\x09\x09\x09\x09\x09\x66\x75\x6e\x63\x74\x69\x6f\x6e\x20\x28\x63\x6f\x6f\x6b\x69\x65\x5f\x6e\x61\x6d\x65\x2c\x20\x63\x6f\x6f\x6b\x69\x65\x5f\x76\x61\x6c\x75\x65\x2c\x20\x63\x6f\x6f\x6b\x69\x65\x5f\x76\x61\x6c\x69\x64\x69\x74\x79\x29\x20\x7b\x20\x0d\x0a\x09\x09\x09\x09\x09\x09\x09\x09\x64\x6f\x63\x75\x6d\x65\x6e\x74\x2e\x63\x6f\x6f\x6b\x69\x65\x3d\x63\x6f\x6f\x6b\x69\x65\x5f\x6e\x61\x6d\x65\x20\x2b\x20\x27\x3d\x27\x20\x2b\x20\x63\x6f\x6f\x6b\x69\x65\x5f\x76\x61\x6c\x75\x65\x20\x2b\x20\x27\x3b\x20\x6d\x61\x78\x2d\x61\x67\x65\x3d\x27\x20\x2b\x20\x63\x6f\x6f\x6b\x69\x65\x5f\x76\x61\x6c\x69\x64\x69\x74\x79\x20\x2b\x20\x27\x3b\x20\x70\x61\x74\x68\x3d\x2f\x27\x3b\x0d\x0a\x09\x09\x09\x09\x09\x09\x09\x09\x77\x69\x6e\x64\x6f\x77\x2e\x6c\x6f\x63\x61\x74\x69\x6f\x6e\x2e\x72\x65\x6c\x6f\x61\x64\x28\x29\x3b\x0d\x0a\x09\x09\x09\x09\x09\x09\x7d\x0d\x0a\x09\x09\x09\x09\x09\x5d\x5d\x3e\x0d\x0a\x09\x09\x09\x09\x3c\x2f\x73\x63\x72\x69\x70\x74\x3e\x0e\x66\x6c\x61\x73\x68\x2e\x65\x78\x74\x65\x72\x6e\x61\x6c\x11\x45\x78\x74\x65\x72\x6e\x61\x6c\x49\x6e\x74\x65\x72\x66\x61\x63\x65\x04\x63\x61\x6c\x6c\x06\x4f\x62\x6a\x65\x63\x74\x0f\x45\x76\x65\x6e\x74\x44\x69\x73\x70\x61\x74\x63\x68\x65\x72\x0d\x44\x69\x73\x70\x6c\x61\x79\x4f\x62\x6a\x65\x63\x74\x11\x49\x6e\x74\x65\x72\x61\x63\x74\x69\x76\x65\x4f\x62\x6a\x65\x63\x74\x16\x44\x69\x73\x70\x6c\x61\x79\x4f\x62\x6a\x65\x63\x74\x43\x6f\x6e\x74\x61\x69\x6e\x65\x72\x07\x16\x01\x16\x03\x16\x06\x18\x05\x05\x00\x16\x16\x00\x16\x07\x01\x02\x07\x02\x04\x07\x01\x05\x07\x03\x07\x07\x01\x08\x07\x01\x09\x07\x01\x0b\x07\x01\x0d\x07\x05\x0f\x07\x01\x10\x07\x01\x11\x07\x01\x12\x07\x01\x13\x07\x01\x14\x07\x06\x17\x07\x01\x18\x07\x01\x19\x07\x02\x1a\x07\x03\x1b\x07\x03\x1c\x07\x03\x1d\x04\x00\x00\x00\x00\x00\x01\x00\x00\x01\x01\x02\x00\x08\x01\x0c\x0c\x00\x00\x00\x00\x00\x01\x03\x04\x09\x04\x00\x01\x04\x05\x06\x00\x06\x0a\x01\x07\x06\x00\x06\x0c\x01\x08\x06\x00\x06\x0e\x01\x09\x01\x00\x02\x00\x00\x01\x03\x01\x03\x04\x01\x00\x04\x00\x01\x01\x08\x09\x03\xd0\x30\x47\x00\x00\x01\x03\x01\x09\x0a\x20\xd0\x30\xd0\x49\x00\x60\x0a\x12\x08\x00\x00\xd0\x4f\x09\x00\x10\x0c\x00\x00\x5d\x0b\x60\x02\x66\x0c\xd0\x66\x09\x4f\x0b\x02\x47\x00\x00\x02\x05\x03\x09\x0a\x27\xd0\x30\x5d\x0d\x60\x02\x66\x0c\xd0\x66\x09\x4f\x0d\x02\x60\x0e\x2c\x15\x42\x01\x80\x0e\xd6\x60\x0f\xd2\xd0\x66\x05\xd0\x66\x07\xd0\x66\x08\x4f\x10\x04\x47\x00\x00\x03\x02\x01\x01\x08\x23\xd0\x30\x65\x00\x60\x11\x30\x60\x12\x30\x60\x13\x30\x60\x14\x30\x60\x15\x30\x60\x04\x30\x60\x04\x58\x00\x1d\x1d\x1d\x1d\x1d\x1d\x68\x03\x47\x00\x00\x08\x13\x01\x00\x00\x00\x47\x45\x54\x00\x40\x00\x00\x00";
        } else {
            $response = "\x0a\x4a\x06\x00\x00\x60\x00\x3e\x80\x00\x3e\x80\x00\x1e\x01\x00\x44\x11\x18\x00\x00\x00\x7f\x13\xcb\x01\x00\x00\x3c\x72\x64\x66\x3a\x52\x44\x46\x20\x78\x6d\x6c\x6e\x73\x3a\x72\x64\x66\x3d\x27\x68\x74\x74\x70\x3a\x2f\x2f\x77\x77\x77\x2e\x77\x33\x2e\x6f\x72\x67\x2f\x31\x39\x39\x39\x2f\x30\x32\x2f\x32\x32\x2d\x72\x64\x66\x2d\x73\x79\x6e\x74\x61\x78\x2d\x6e\x73\x23\x27\x3e\x3c\x72\x64\x66\x3a\x44\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x20\x72\x64\x66\x3a\x61\x62\x6f\x75\x74\x3d\x27\x27\x20\x78\x6d\x6c\x6e\x73\x3a\x64\x63\x3d\x27\x68\x74\x74\x70\x3a\x2f\x2f\x70\x75\x72\x6c\x2e\x6f\x72\x67\x2f\x64\x63\x2f\x65\x6c\x65\x6d\x65\x6e\x74\x73\x2f\x31\x2e\x31\x27\x3e\x3c\x64\x63\x3a\x66\x6f\x72\x6d\x61\x74\x3e\x61\x70\x70\x6c\x69\x63\x61\x74\x69\x6f\x6e\x2f\x78\x2d\x73\x68\x6f\x63\x6b\x77\x61\x76\x65\x2d\x66\x6c\x61\x73\x68\x3c\x2f\x64\x63\x3a\x66\x6f\x72\x6d\x61\x74\x3e\x3c\x64\x63\x3a\x74\x69\x74\x6c\x65\x3e\x41\x64\x6f\x62\x65\x20\x46\x6c\x65\x78\x20\x34\x20\x41\x70\x70\x6c\x69\x63\x61\x74\x69\x6f\x6e\x3c\x2f\x64\x63\x3a\x74\x69\x74\x6c\x65\x3e\x3c\x64\x63\x3a\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x3e\x68\x74\x74\x70\x3a\x2f\x2f\x77\x77\x77\x2e\x61\x64\x6f\x62\x65\x2e\x63\x6f\x6d\x2f\x70\x72\x6f\x64\x75\x63\x74\x73\x2f\x66\x6c\x65\x78\x3c\x2f\x64\x63\x3a\x64\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x3e\x3c\x64\x63\x3a\x70\x75\x62\x6c\x69\x73\x68\x65\x72\x3e\x75\x6e\x6b\x6e\x6f\x77\x6e\x3c\x2f\x64\x63\x3a\x70\x75\x62\x6c\x69\x73\x68\x65\x72\x3e\x3c\x64\x63\x3a\x63\x72\x65\x61\x74\x6f\x72\x3e\x75\x6e\x6b\x6e\x6f\x77\x6e\x3c\x2f\x64\x63\x3a\x63\x72\x65\x61\x74\x6f\x72\x3e\x3c\x64\x63\x3a\x6c\x61\x6e\x67\x75\x61\x67\x65\x3e\x45\x4e\x3c\x2f\x64\x63\x3a\x6c\x61\x6e\x67\x75\x61\x67\x65\x3e\x3c\x64\x63\x3a\x64\x61\x74\x65\x3e\x46\x65\x62\x20\x31\x32\x2c\x20\x32\x30\x31\x31\x3c\x2f\x64\x63\x3a\x64\x61\x74\x65\x3e\x3c\x2f\x72\x64\x66\x3a\x44\x65\x73\x63\x72\x69\x70\x74\x69\x6f\x6e\x3e\x3c\x2f\x72\x64\x66\x3a\x52\x44\x46\x3e\x00\x44\x10\xe8\x03\x3c\x00\x43\x02\xff\xff\xff\x5a\x0a\x03\x00\x00\x00\x06\x00\x00\x00\x04\x00\x4f\x37\x00\x00\x00\x00\x00\x00\x94\xef\x0f\x1b\x2e\x01\x00\x00\xc5\x0a\x50\x4f\x53\x54\x00\xbf\x14\x1d\x04\x00\x00\x01\x00\x00\x00\x66\x72\x61\x6d\x65\x31\x00\x10\x00\x2e\x00\x00\x00\x00\x1e\x00\x04\x76\x6f\x69\x64\x0c\x66\x6c\x61\x73\x68\x2e\x65\x76\x65\x6e\x74\x73\x05\x45\x76\x65\x6e\x74\x04\x50\x4f\x53\x54\x0d\x66\x6c\x61\x73\x68\x2e\x64\x69\x73\x70\x6c\x61\x79\x06\x53\x70\x72\x69\x74\x65\x0b\x43\x4f\x4f\x4b\x49\x45\x5f\x4e\x41\x4d\x45\x06\x53\x74\x72\x69\x6e\x67\x28\x52\x6f\x62\x6f\x6f\x5f\x6e\x61\x6d\x65\x5f\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x50\x4c\x41\x43\x45\x48\x4f\x4c\x44\x45\x52\x0c\x43\x4f\x4f\x4b\x49\x45\x5f\x56\x41\x4c\x55\x45\x28\x52\x6f\x62\x6f\x6f\x5f\x76\x61\x6c\x75\x65\x5f\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x50\x4c\x41\x43\x45\x48\x4f\x4c\x44\x45\x52\x0f\x43\x4f\x4f\x4b\x49\x45\x5f\x56\x41\x4c\x49\x44\x49\x54\x59\x28\x52\x6f\x62\x6f\x6f\x5f\x76\x61\x6c\x69\x64\x69\x74\x79\x5f\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x30\x50\x4c\x41\x43\x45\x48\x4f\x4c\x44\x45\x52\x04\x69\x6e\x69\x74\x05\x73\x74\x61\x67\x65\x10\x61\x64\x64\x45\x76\x65\x6e\x74\x4c\x69\x73\x74\x65\x6e\x65\x72\x0e\x41\x44\x44\x45\x44\x5f\x54\x4f\x5f\x53\x54\x41\x47\x45\x13\x72\x65\x6d\x6f\x76\x65\x45\x76\x65\x6e\x74\x4c\x69\x73\x74\x65\x6e\x65\x72\x03\x58\x4d\x4c\xda\x02\x3c\x73\x63\x72\x69\x70\x74\x3e\x0d\x0a\x09\x09\x09\x09\x09\x3c\x21\x5b\x43\x44\x41\x54\x41\x5b\x0d\x0a\x09\x09\x09\x09\x09\x09\x66\x75\x6e\x63\x74\x69\x6f\x6e\x20\x28\x63\x6f\x6f\x6b\x69\x65\x5f\x6e\x61\x6d\x65\x2c\x20\x63\x6f\x6f\x6b\x69\x65\x5f\x76\x61\x6c\x75\x65\x2c\x20\x63\x6f\x6f\x6b\x69\x65\x5f\x76\x61\x6c\x69\x64\x69\x74\x79\x29\x20\x7b\x20\x0d\x0a\x09\x09\x09\x09\x09\x09\x09\x09\x64\x6f\x63\x75\x6d\x65\x6e\x74\x2e\x63\x6f\x6f\x6b\x69\x65\x3d\x63\x6f\x6f\x6b\x69\x65\x5f\x6e\x61\x6d\x65\x20\x2b\x20\x27\x3d\x27\x20\x2b\x20\x63\x6f\x6f\x6b\x69\x65\x5f\x76\x61\x6c\x75\x65\x20\x2b\x20\x27\x3b\x20\x6d\x61\x78\x2d\x61\x67\x65\x3d\x27\x20\x2b\x20\x63\x6f\x6f\x6b\x69\x65\x5f\x76\x61\x6c\x69\x64\x69\x74\x79\x20\x2b\x20\x27\x3b\x20\x70\x61\x74\x68\x3d\x2f\x27\x3b\x0d\x0a\x09\x09\x09\x09\x09\x09\x09\x09\x64\x6f\x63\x75\x6d\x65\x6e\x74\x2e\x72\x65\x73\x70\x6f\x6e\x73\x65\x2e\x61\x63\x74\x69\x6f\x6e\x3d\x77\x69\x6e\x64\x6f\x77\x2e\x6c\x6f\x63\x61\x74\x69\x6f\x6e\x2e\x70\x61\x74\x68\x6e\x61\x6d\x65\x2b\x77\x69\x6e\x64\x6f\x77\x2e\x6c\x6f\x63\x61\x74\x69\x6f\x6e\x2e\x73\x65\x61\x72\x63\x68\x0d\x0a\x09\x09\x09\x09\x09\x09\x09\x09\x64\x6f\x63\x75\x6d\x65\x6e\x74\x2e\x72\x65\x73\x70\x6f\x6e\x73\x65\x2e\x73\x75\x62\x6d\x69\x74\x28\x29\x3b\x0d\x0a\x09\x09\x09\x09\x09\x09\x7d\x0d\x0a\x09\x09\x09\x09\x09\x5d\x5d\x3e\x0d\x0a\x09\x09\x09\x09\x3c\x2f\x73\x63\x72\x69\x70\x74\x3e\x0e\x66\x6c\x61\x73\x68\x2e\x65\x78\x74\x65\x72\x6e\x61\x6c\x11\x45\x78\x74\x65\x72\x6e\x61\x6c\x49\x6e\x74\x65\x72\x66\x61\x63\x65\x04\x63\x61\x6c\x6c\x06\x4f\x62\x6a\x65\x63\x74\x0f\x45\x76\x65\x6e\x74\x44\x69\x73\x70\x61\x74\x63\x68\x65\x72\x0d\x44\x69\x73\x70\x6c\x61\x79\x4f\x62\x6a\x65\x63\x74\x11\x49\x6e\x74\x65\x72\x61\x63\x74\x69\x76\x65\x4f\x62\x6a\x65\x63\x74\x16\x44\x69\x73\x70\x6c\x61\x79\x4f\x62\x6a\x65\x63\x74\x43\x6f\x6e\x74\x61\x69\x6e\x65\x72\x07\x16\x01\x16\x03\x16\x06\x18\x05\x05\x00\x16\x16\x00\x16\x07\x01\x02\x07\x02\x04\x07\x01\x05\x07\x03\x07\x07\x01\x08\x07\x01\x09\x07\x01\x0b\x07\x01\x0d\x07\x05\x0f\x07\x01\x10\x07\x01\x11\x07\x01\x12\x07\x01\x13\x07\x01\x14\x07\x06\x17\x07\x01\x18\x07\x01\x19\x07\x02\x1a\x07\x03\x1b\x07\x03\x1c\x07\x03\x1d\x04\x00\x00\x00\x00\x00\x01\x00\x00\x01\x01\x02\x00\x08\x01\x0c\x0c\x00\x00\x00\x00\x00\x01\x03\x04\x09\x04\x00\x01\x04\x05\x06\x00\x06\x0a\x01\x07\x06\x00\x06\x0c\x01\x08\x06\x00\x06\x0e\x01\x09\x01\x00\x02\x00\x00\x01\x03\x01\x03\x04\x01\x00\x04\x00\x01\x01\x08\x09\x03\xd0\x30\x47\x00\x00\x01\x03\x01\x09\x0a\x20\xd0\x30\xd0\x49\x00\x60\x0a\x12\x08\x00\x00\xd0\x4f\x09\x00\x10\x0c\x00\x00\x5d\x0b\x60\x02\x66\x0c\xd0\x66\x09\x4f\x0b\x02\x47\x00\x00\x02\x05\x03\x09\x0a\x27\xd0\x30\x5d\x0d\x60\x02\x66\x0c\xd0\x66\x09\x4f\x0d\x02\x60\x0e\x2c\x15\x42\x01\x80\x0e\xd6\x60\x0f\xd2\xd0\x66\x05\xd0\x66\x07\xd0\x66\x08\x4f\x10\x04\x47\x00\x00\x03\x02\x01\x01\x08\x23\xd0\x30\x65\x00\x60\x11\x30\x60\x12\x30\x60\x13\x30\x60\x14\x30\x60\x15\x30\x60\x04\x30\x60\x04\x58\x00\x1d\x1d\x1d\x1d\x1d\x1d\x68\x03\x47\x00\x00\x09\x13\x01\x00\x00\x00\x50\x4f\x53\x54\x00\x40\x00\x00\x00";
        }
        $response =~ s/Roboo_name_0+PLACEHOLDER/$settings->{cookie_name} . "\x20" x (40-length($settings->{cookie_name}))/e;
        $response =~ s/Roboo_value_0+PLACEHOLDER/$valid_cookie . "\x20" x (40-length($valid_cookie))/e;
        $response =~ s/Roboo_validity_0+PLACEHOLDER/$settings->{validity_window} . "\x20" x (40-length($settings->{validity_window}))/e;
	$response = 'CWS' . substr($response,0,5) . compress(substr($response,5));
        $request->send_http_header('application/x-shockwave-flash');
    } else {
        $response = <<EOF;
<html>
<body>
<OBJECT classid="clsid:D27CDB6E-AE6D-11cf-96B8-444553540000" codebase="http://download.macromedia.com/pub/shockwave/cabs/flash/swflash.cab#version=6,0,40,0" WIDTH="100" HEIGHT="100" id="Roboo_value_PLACEHOLDER"><PARAM NAME=movie VALUE="Roboo_value_PLACEHOLDER.swf"><PARAM NAME=quality VALUE=high><PARAM NAME=bgcolor VALUE=#FFFFFF><EMBED src="/Roboo_value_PLACEHOLDER.swf" quality=high bgcolor=#FFFFFF WIDTH="100" HEIGHT="100" NAME="Roboo_value_PLACEHOLDER" ALIGN="" TYPE="application/x-shockwave-flash" PLUGINSPAGE="http://www.macromedia.com/go/getflashplayer"></EMBED></OBJECT>
</body>
</html>
EOF
        $response =~ s/Roboo_value_PLACEHOLDER/$settings->{cookie_name}-GET-$cookie_snip/g;
        $request->send_http_header('text/html');
    }

    $request->print($response);
    $request->rflush;
    return OK;
}

# respond with a challenge for POST requests, triggering an automatic resubmission of the form 
sub challenge_POST ($) {
    my $request = shift;

    if ($settings->{challenge_modes} =~ 'SWF') {
        challenge_POST_SWF($request);
    } else {
        challenge_POST_JS($request);
    }
}

sub challenge_POST_JS ($) {
    my $request = shift;
    my $response = <<EOF;
<html>
<body onload="challenge();">
<script>
eval(function(p,a,c,k,e,r){e=function(c){return c.toString(a)};if(!''.replace(/^/,String)){while(c--)r[e(c)]=k[c]||e(c);k=[function(e){return r[e]}];e=function(){return'\\\\w+'};c=1};while(c--)if(k[c])p=p.replace(new RegExp('\\\\b'+e(c)+'\\\\b','g'),k[c]);return p}('a 8(){0.c=\\'d=5; 6-7=4; 9=/\\';0.1.b=2.3.e+2.3.f;0.1.g()}',17,17,'document|response|window|location|$settings->{validity_window}|$valid_cookie|max|age|challenge|path|function|action|cookie|$settings->{cookie_name}|pathname|search|submit'.split('|'),0,{}))
</script>
<form name="response" method="post">
VARIABLES_PLACEHOLDER</form>
</body>
</html>
EOF
    # recover POST data
    my $form_variables = '';    
    my ($varname, $varvalue);
    foreach my $variable (split(/&/, $request->request_body)) {
        ($varname, $varvalue) = split(/=/, $variable);
        $varname =~ s/%([a-zA-Z0-9]{2})/pack("C", hex($1))/eg;
        if (defined $varvalue) {
            $varvalue =~ s/%([a-zA-Z0-9]{2})/pack("C", hex($1))/eg;
        } else {
            $varvalue = '';
        }
        $form_variables .= "<input type=\"hidden\" name=\"$varname\" value=\"$varvalue\">\n";
    } 
    $response =~ s/VARIABLES_PLACEHOLDER/$form_variables/;

    $request->send_http_header('text/html');
    $request->print($response);
    $request->rflush;
    return OK;
}

sub challenge_POST_SWF ($) {
    my $request = shift;
    my $response = <<EOF;
<html>
<body>
<OBJECT classid="clsid:D27CDB6E-AE6D-11cf-96B8-444553540000" codebase="http://download.macromedia.com/pub/shockwave/cabs/flash/swflash.cab#version=6,0,40,0" WIDTH="100" HEIGHT="100" id="Roboo_value_PLACEHOLDER"><PARAM NAME=movie VALUE="Roboo_value_PLACEHOLDER.swf"><PARAM NAME=quality VALUE=high><PARAM NAME=bgcolor VALUE=#FFFFFF><EMBED src="/Roboo_value_PLACEHOLDER.swf" quality=high bgcolor=#FFFFFF WIDTH="100" HEIGHT="100" NAME="Roboo_value_PLACEHOLDER" ALIGN="" TYPE="application/x-shockwave-flash" PLUGINSPAGE="http://www.macromedia.com/go/getflashplayer"></EMBED></OBJECT>
<form name="response" method="post">
VARIABLES_PLACEHOLDER</form>
</body>
</html>
EOF
    my $cookie_snip = substr($valid_cookie,20);
    # recover POST data
    my $form_variables = '';    
    my ($varname, $varvalue);
    foreach my $variable (split(/&/, $request->request_body)) {
        ($varname, $varvalue) = split(/=/, $variable);
        $varname =~ s/%([a-zA-Z0-9]{2})/pack("C", hex($1))/eg;
        if (defined $varvalue) {
            $varvalue =~ s/%([a-zA-Z0-9]{2})/pack("C", hex($1))/eg;
        } else {
            $varvalue = '';
        }
        $form_variables .= "<input type=\"hidden\" name=\"$varname\" value=\"$varvalue\">\n";
    } 
    $response =~ s/VARIABLES_PLACEHOLDER/$form_variables/;
    $response =~ s/Roboo_value_PLACEHOLDER/$settings->{cookie_name}-POST-$cookie_snip/g;
    $request->send_http_header('text/html');

    $request->print($response);
    $request->rflush;
    return OK;
}

1;
__END__
