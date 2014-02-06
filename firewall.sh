#!/bin/bash


### BEGIN INIT INFO
# Provides:          firewall
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: LiHAS Firewall
# Description:       Firewall
### END INIT INFO

# Author: Adrian Reyer <are@lihas.de>
# $Id$
#

# Do NOT "set -e"

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DESC="LiHAS Firewall"
NAME=firewall
DAEMON=/bin/true
SCRIPTNAME=/etc/init.d/$NAME
CONFIGDIR=/etc/firewall.lihas.d
LIBDIR=/usr/lib/firewall-lihas
TMPDIR=${TMPDIR:-/tmp}

DATAPATH=/var/lib/firewall-lihas
DATABASE=$DATAPATH/db.sqlite
LOGSTARTUP=$TMPDIR/firewall-lihas-startup.log

# Default values
# TARGETLOG: LOG-Chain, mostly useful: LOG ULOG
TARGETLOG=LOG

# Read configuration variable file if it is present
[ -r /etc/default/$NAME ] && . /etc/default/$NAME

# Reset startup logfile
echo -n > $LOGSTARTUP

# Exit if the package is not installed
[ -x "$DAEMON" ] || exit 0

FILE=$TMPDIR/iptables
FILEfilter=$TMPDIR/iptables-filter
FILEnat=$TMPDIR/iptables-nat
FILEmangle=$TMPDIR/iptables-mangle


if [ -e $CONFIGDIR/config.xml ]; then
  DATAPATH=$(xmlstarlet sel -t -v /applicationconfig/application/config/@db_dbd /etc/firewall.lihas.d/config.xml)
  DATABASE=$DATAPATH/db.sqlite
fi

export CONFIGDIR LIBDIR TMPDIR FILE FILEfilter FILEnat FILEmangle TARGETLOG DATABASE DATAPATH
mkdir -p "$DATAPATH"

# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.0-6) to ensure that this file is present.
. /lib/lsb/init-functions

do_reload() {
        do_start
        return 0
}

do_start() {

ipt_cmd=0
ipt_err=0

set -a

[ -d "$CONFIGDIR" ] && cd "$CONFIGDIR"

rm $FILE $FILEfilter $FILEnat $FILEmangle
exec 4>$FILE 5>$FILEfilter 6>$FILEnat 7>$FILEmangle

HAVE_COMMENT=0
HAVE_LOG=0
HAVE_ULOG=0
HAVE_IPSET=0
# check availability of modules:
iptables -N lihas-moduletest
iptables -A lihas-moduletest $CONNSTATE 2>/dev/null
if iptables-save | egrep -q 'lihas-moduletest.*-m state'; then
  CONNSTATE="-m state --state"
else
  CONNSTATE="-m conntrack --ctstate"
fi
iptables -A lihas-moduletest -m comment --comment "test"
if [ $? -eq 0 ]; then
  HAVE_COMMENT=1
fi
iptables -A lihas-moduletest -j LOG --log-prefix 'test'
if [ $? -eq 0 ]; then
  HAVE_LOG=1
fi
iptables -A lihas-moduletest -j ULOG --ulog-prefix 'test'
if [ $? -eq 0 ]; then
  HAVE_ULOG=1
fi
# check if ipset is available
if [ type -a ipset > /dev/null ]; then
  ipset create lihas-moduletest bitmap:ip,mac range 127.0.0.0/24
  if [ $? -eq 0 ]; then
    iptables -A lihas-moduletest -m set --match-set lihas-moduletest src,src 2>/dev/null >&2
    if [ $? -eq 0 ]; then
      HAVE_IPSET=1
    fi
    ipset destroy lihas-moduletest
  fi
fi
iptables -F lihas-moduletest
iptables -X lihas-moduletest

# determine LOG target
if [ $TARGETLOG == "LOG" ] && [ $HAVE_LOG -eq 1 ]; then
  TARGETLOG=LOG
elif [ $TARGETLOG == "ULOG" ] && [ $HAVE_ULOG -eq 1 ]; then
  TARGETLOG=ULOG
elif [ $HAVE_LOG -eq 1 ]; then
  TARGETLOG=LOG
elif [ $HAVE_ULOG -eq 1 ]; then
  TARGETLOG=ULOG
fi

export TARGETLOG HAVE_COMMENT HAVE_LOG HAVE_ULOG HAVE_IPSET
  
. $LIBDIR/helper-dns.sh
. $LIBDIR/helper-group.sh
. $LIBDIR/lihas_ipt_reject.sh
. $LIBDIR/ipset-setup.sh

echo "Allowing all established Connections"
for chain in INPUT OUTPUT FORWARD; do
  echo ":$chain DROP" >&5
done
for chain in INPUT OUTPUT FORWARD; do
  echo "-A $chain $CONNSTATE ESTABLISHED,RELATED -j ACCEPT" >&5
done
for chain in PREROUTING POSTROUTING OUTPUT; do
  echo ":$chain ACCEPT" >&6
done
for chain in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
  echo ":$chain ACCEPT" >&7
done

for iface in interface-*; do
  iface=${iface#interface-}
  echo ":in-$iface -" >&5
  echo ":out-$iface -" >&5
  echo ":fwd-$iface -" >&5
  echo ":dns-in-$iface -" >&5
  echo ":dns-out-$iface -" >&5
  echo ":dns-fwd-$iface -" >&5

  echo ":pre-$iface -" >&6
  echo ":post-$iface -" >&6
  echo ":dns-pre-$iface -" >&6
  echo ":dns-post-$iface -" >&6
done

echo "Setting up IPSEC Spoof Protection"
for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/network-ipsec ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/network-ipsec | sed '/^[ \t]*$/d; /^#/d' |
    while read network; do
      echo "-A PREROUTING -p esp -j MARK --set-mark 8000/0000" >&7
      echo "-A PREROUTING -p ah -j MARK --set-mark 8000/0000" >&7
      echo "-A in-$iface -s $network -i $iface -m mark ! --mark 8000/8000 -j $TARGETLOG" >&5
      echo "-A fwd-$iface -s $network -i $iface -m mark ! --mark 8000/8000 -j $TARGETLOG" >&5
      echo "-A in-$iface -s $network -i $iface -m mark ! --mark 8000/8000 -j DROP" >&5
      echo "-A fwd-$iface -s $network -i $iface -m mark ! --mark 8000/8000 -j DROP" >&5
    done
  fi
  echo "-A PREROUTING -i $iface -j pre-$iface" >&6
  echo "-A POSTROUTING -o $iface -j post-$iface" >&6
done

echo "Setting up Chains"
for iface in interface-*; do
  iface=${iface#interface-}
  if [ ${iface} == "lo" ]; then
    echo "-A OUTPUT -j in-$iface" >&5
    echo "-A OUTPUT -j pre-$iface" >&6
    echo "-A POSTROUTING -o $iface -j post-$iface" >&6
    echo "-A OUTPUT -j dns-in-$iface" >&5
    echo "-A OUTPUT -j dns-pre-$iface" >&6
    echo "-A POSTROUTING -o $iface -j dns-post-$iface" >&6
  else
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    if [ -e interface-$iface/network ]; then
      cat interface-$iface/network | sed '/^[ \t]*$/d; /^#/d' |
      while read network; do
        echo "-A INPUT -s $network -i $iface -j in-$iface"
        echo "-A OUTPUT -d $network -o $iface -j out-$iface"
        echo "-A FORWARD -s $network -i $iface -j fwd-$iface"
        echo "-A INPUT -s $network -i $iface -j dns-in-$iface"
        echo "-A OUTPUT -d $network -o $iface -j dns-out-$iface"
        echo "-A FORWARD -s $network -i $iface -j dns-fwd-$iface" 
      done >&5
    else
      echo "WARNING: Interface $iface has no network file"
    fi
    echo "-A PREROUTING -i $iface -j pre-$iface" >&6
    echo "-A POSTROUTING -o $iface -j post-$iface" >&6
    echo "-A PREROUTING -i $iface -j dns-pre-$iface" >&6
    echo "-A POSTROUTING -o $iface -j dns-post-$iface" >&6
  fi
done

echo "Loopback Interface is fine"
echo "-A OUTPUT	-j ACCEPT -o lo" >&5
echo "-A INPUT	-j ACCEPT -i lo" >&5

if [ -e ./script-pre ]; then
  echo "Hook: script-pre"
  . ./script-pre
fi

echo "Avoiding NAT"
lihas_ipt_nonat () {
  outfile=$1
  snet=$2
  dnet=$3
  proto=$4
  dport=$5
  if [ $snet == "include" ]; then
    if [ -e $snet ]; then
      cat $mnet | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read snet dnet proto dport; do
        lihas_ipt_nonat "$outfile" "$snet" "$dnet" "$proto" "$dport"
      done
    else
      echo "$snet doesn't exist"
    fi
  else
    if [ $dport == "0" ]; then
      echo "-A post-$iface -s $snet -d $dnet -p $proto -j ACCEPT " >&6
    else
      echo "-A post-$iface -s $snet -d $dnet -p $proto --dport $dport -j ACCEPT" >> $outfile
    fi
  fi
}

for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/nonat ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/nonat | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport; do
      lihas_ipt_nonat "$FILEnat" "$snet" "$dnet" "$proto" "$dport"
    done
  fi
done

echo "Adding DNAT"
lihas_ipt_dnat () {
  outfile=$1
  dnet=$2
  mnet=$3
  proto=$4
  dport=$5
  ndport=$6
  if [ $dnet == "include" ]; then
    if [ -e $mnet ]; then
      cat $mnet | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read dnet mnet proto dport ndport; do
        lihas_ipt_dnat "$outfile" "$dnet" "$mnet" "$proto" "$dport" "$ndport"
      done
    else
      echo "$mnet doesn't exist"
    fi
  else
    if [ $dnet == ACCEPT ]; then
      if [ $dport == "0" ]; then
        echo "-A pre-$iface -s $mnet -p $proto -j ACCEPT" >&6
      else
        if [ $proto == "icmp" ]; then
          echo "-A pre-$iface -s $mnet -p $proto --icmp-type $dport -j ACCEPT" >> $outfile
        else 
          echo "-A pre-$iface -s $mnet -p $proto --dport $dport -j ACCEPT" >> $outfile
        fi
      fi
    else
      if [ $dport == "0" ]; then
        echo "-A pre-$iface -d $dnet -p $proto -j DNAT --to-destination $mnet" >&6
      else
        ndport=${ndport//:/-}
        if [ $proto == "icmp" ]; then
          echo "-A pre-$iface -d $dnet -p $proto --icmp-type $dport -j DNAT --to-destination $mnet:$ndport" >> $outfile
        else 
          echo "-A pre-$iface -d $dnet -p $proto --dport $dport -j DNAT --to-destination $mnet:$ndport" >> $outfile
        fi
      fi
    fi
  fi
}

for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/dnat ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/dnat | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read dnet mnet proto dport ndport; do
      lihas_ipt_dnat "$FILEnat" "$dnet" "$mnet" "$proto" "$dport" "$ndport"
    done
  fi
done


lihas_ipt_snat () {
  outfile=$1
  dnet=$2
  mnet=$3
  proto=$4
  dport=$5
  if [ $dnet == "include" ]; then
    if [ -e $mnet ]; then
      cat $mnet | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read snet mnet proto dport; do
        lihas_ipt_snat "$outfile" "$snet" "$mnet" "$proto" "$dport"
      done
    else
      echo "$mnet doesn't exist"
    fi
  else
    if [ $dnet == ACCEPT ]; then
      if [ $dport == "0" ]; then
        echo "-A post-$iface -s $snet -p $proto -j ACCEPT" >&6
      else
        if [ $proto == "icmp" ]; then
          echo "-A post-$iface -s $snet -p $proto --icmp-type  $dport -j ACCEPT" >> $outfile
        else
          echo "-A post-$iface -s $snet -p $proto --dport $dport -j ACCEPT" >> $outfile
        fi
      fi
    else
      if [ $dport == "0" ]; then
        echo "-A post-$iface -s $snet -p $proto -j SNAT --to-source $mnet" >&6
      else
        if [ $proto == "icmp" ]; then
          echo "-A post-$iface -s $snet -p $proto --icmp-type  $dport -j SNAT --to-source $mnet" >> $outfile
        else
          echo "-A post-$iface -s $snet -p $proto --dport $dport -j SNAT --to-source $mnet" >> $outfile
        fi
      fi
    fi
  fi
}
echo "Adding SNAT"
for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/snat ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/snat | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet mnet proto dport; do
        lihas_ipt_snat "$FILEnat" "$snet" "$mnet" "$proto" "$dport"
    done
  fi
done

echo "Adding MASQUERADE"
lihas_ipt_masquerade () {
  outfile=$1
  snet=$2
  mnet=$3
  proto=$4
  dport=$5
  if [ $snet == "include" ]; then
    if [ -e $mnet ]; then
      cat $mnet | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read snet mnet proto dport; do
        lihas_ipt_masquerade "$outfile" "$snet" "$mnet" "$proto" "$dport"
      done
    else
      echo "$mnet doesn't exist"
    fi
  else
    if [ $dport == "0" ]; then
      echo "-A post-$iface -s $snet -p $proto -j MASQUERADE" >> $outfile
    else
      if [ $proto == "icmp" ]; then
        echo "-A post-$iface -s $snet -p $proto --icmp-type  $dport -j MASQUERADE" >> $outfile
      else 
        echo "-A post-$iface -s $snet -p $proto --dport $dport -j MASQUERADE" >> $outfile
      fi
    fi
  fi
}

for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/masquerade ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/masquerade | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet mnet proto dport; do
      lihas_ipt_masquerade "$FILEnat" "$snet" "$mnet" "$proto" "$dport"
    done
  fi
done

echo "Rejecting extra Clients"
for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/reject ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/reject | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport oiface; do
      lihas_ipt_rejectclients "$snet" "$dnet" "$proto" "$dport" "$oiface"
    done
  fi
done

echo "Adding priviledged Clients"
lihas_ipt_privclients () {
  snet=$1
  dnet=$2
  proto=$3
  dport=$4
  oiface=$5
  if [ "$snet" == "include" ]; then
    if [ -e "$dnet" ]; then
      cat $dnet | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read snet dnet proto dport oiface; do
        lihas_ipt_privclients "$snet" "$dnet" "$proto" "$dport" "$oiface"
      done
    else
      echo "$snet doesn't exist"
    fi
  else
    if [ $dport == "0" ]; then
      if [ "ga$oiface" == "ga" ]; then
        echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -j ACCEPT" >&5
        echo "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -j ACCEPT" >&5
      else
        echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -o $oiface -j ACCEPT" >&5
      fi
    else
      if [ "ga$oiface" == "ga" ]; then
        if [ $proto == "icmp" ]; then
          echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -j ACCEPT" >&5
          echo "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -j ACCEPT" >&5
        else 
          echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -j ACCEPT" >&5
          echo "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -j ACCEPT" >&5
        fi
      else
        if [ $proto == "icmp" ]; then
          echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -o $oiface -j ACCEPT" >&5
        else 
          echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -o $oiface -j ACCEPT" >&5
        fi
      fi
    fi
  fi
}

for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/privclients ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/privclients | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport oiface; do
      lihas_ipt_privclients "$snet" "$dnet" "$proto" "$dport" "$oiface"
    done
  fi
done


echo Policy Routing
echo "-I PREROUTING -j MARK --set-mark 0" >&7
echo "-I OUTPUT -j MARK --set-mark 0" >&7
for policy in policy-routing-*; do
  policy=${policy#policy-routing-}
  if ! ip route ls table $policy >/dev/null 2>&1; then
    echo "Please add '$policy' to /etc/iproute2/rt_tables or policy routing won't work. If you don't want policy routing, feel free to delete $CONFIGDIR/policy-routing-$policy" | tee -a $LOGSTARTUP
  fi
  if [ -e policy-routing-$policy/key ]; then
    [ -e policy-routing-$policy/comment ] && cat policy-routing-$policy/comment | sed 's/^/ /'
    key=$(cat policy-routing-$policy/key)
    if [ -e policy-routing-$policy/gateway ]; then
      cat policy-routing-$policy/gateway | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read type interface gateway; do
        ip route flush table $policy
        if [ $type == "PPP" ]; then
          ip route ls |
          sed 's/^default.*/default dev '$interface'/' |
          while read a; do
            ip route add $a table $policy
          done
        elif [ $type == "NET" ]; then
          ip route ls |
          sed 's/^default.*/default dev '$interface' via '$gateway'/' |
          while read a; do
            ip route add $a table $policy
          done
        else
          echo Non PPP/NET-Policy-Routing is not implemented
        fi
        while ip rule | egrep -qw "fwmark $key lookup $policy"; do
          ip rule del fwmark $key table $policy
        done
        ip rule add fwmark $key table $policy
        ip route flush cache
      done
    fi
  fi
done
for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/policy-routing ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/policy-routing | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport policy; do
      mark=$(cat policy-routing-$policy/key)
      if [ $dport == "0" ]; then
          echo "-A OUTPUT -s $snet -d $dnet -p $proto -j MARK --set-mark $mark" >&7
          echo "-A PREROUTING -s $snet -d $dnet -p $proto -j MARK --set-mark $mark" >&7
      else
          echo "-A OUTPUT -s $snet -d $dnet -p $proto --dport $dport -j MARK --set-mark $mark" >&7
          echo "-A PREROUTING -s $snet -d $dnet -p $proto --dport $dport -j MARK --set-mark $mark" >&7
      fi
    done
  fi
done

echo LOCALHOST
# There might be legacy FILE* in there, sync
sync
. ./localhost
sync

echo "Disable some logging"
lihas_ipt_nolog () {
  snet=$1
  dnet=$2
  proto=$3
  dport=$4
  oiface=$5
  if [ "$snet" == "include" ]; then
    if [ -e "$dnet" ]; then
      cat $dnet | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read snet dnet proto dport oiface; do
        lihas_ipt_nolog "$snet" "$dnet" "$proto" "$dport" "$oiface"
      done
    else
      echo "$snet doesn't exist"
    fi
  else
    if [ $dport == "0" ]; then
      if [ "ga$oiface" == "ga" ]; then
        echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -j DROP" >&5
        echo "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -j DROP" >&5
      else
        echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -o $oiface -j DROP" >&5
      fi
    else
      if [ "ga$oiface" == "ga" ]; then
        if [ $proto == "icmp" ]; then
          echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -j DROP" >&5
          echo "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -j DROP" >&5
        else 
          echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -j DROP" >&5
          echo "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -j DROP" >&5
        fi
      else
        if [ $proto == "icmp" ]; then
          echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -o $oiface -j DROP" >&5
        else 
          echo "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -o $oiface -j DROP" >&5
        fi
      fi
    fi
  fi
}

for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/nolog ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/nolog | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport oiface; do
      lihas_ipt_nolog "$snet" "$dnet" "$proto" "$dport" "$oiface"
    done
  fi
done

lihas_ipt_mark_dhcpd () {
  iface=$1
  echo "-A INPUT -i $iface -p udp --sport 68 --dport 67 -j ACCEPT" >&5
  echo "-A OUTPUT -o $iface -p udp --sport 67 --dport 68 -j ACCEPT" >&5
}
for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/mark ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    grep -qwi dhcpd interface-$iface/mark && lihas_ipt_mark_dhcpd "$iface"
  fi
done

for chain in INPUT OUTPUT FORWARD; do
  echo "-A $chain -j $TARGETLOG" >&5
done

if [ -e ./script-post ]; then
  echo "Hook: script-post"
  . ./script-post
fi

echo *filter > $FILE
cat $FILEfilter | sed '/-s dns-/d; /-s dns/d' >> $FILE
cat $FILEfilter | sed -n '/-[sd] dns-/p' > $DATAPATH/dns-filter
echo COMMIT >> $FILE
echo *mangle >> $FILE
cat $FILEmangle | sed '/-sd dns-/d; /-s dns/d' >> $FILE
cat $FILEmangle | sed -n '/-[sd] dns-/p' > $DATAPATH/dns-mangle
echo COMMIT >> $FILE
echo *nat >> $FILE
cat $FILEnat | sed '/-d dns-/d; /-s dns/d' >> $FILE
cat $FILEnat | sed -n '/-[sd] dns-/p' > $DATAPATH/dns-nat
echo COMMIT >> $FILE

}

do_stop () {
  iptables-restore < /etc/firewall.lihas.d/iptables-accept
}

FILE=$TMPDIR/iptables

case "$1" in
  test)
        do_start
	echo "Check $FILE to see what it would look like"
	;;
  start)
        [ "$VERBOSE" != no ] && log_daemon_msg "Starting $DESC" "$NAME"
        do_start
        iptables-restore < $FILE
	[ -x /etc/firewall.lihas.d/fw_post_rules ] && /etc/firewall.lihas.d/fw_post_rules
	firewall-lihasd.pl
	if [ -s "$LOGSTARTUP" ]; then
	  echo
	  echo "********************************************************************************"
	  echo "Potential showstoppers:"
	  cat $LOGSTARTUP
        fi
        ;;
  stop)
        [ "$VERBOSE" != no ] && log_daemon_msg "Stopping $DESC" "$NAME"
        do_stop
	kill -INT $(cat /var/state/firewall-lihasd.pid )
        ;;
  reload|force-reload)
        #
        # If do_reload() is not implemented then leave this commented out
        # and leave 'force-reload' as an alias for 'restart'.
        #
        log_daemon_msg "Reloading $DESC" "$NAME"
        do_start
        iptables-restore < $FILE
	[ -x /etc/firewall.lihas.d/fw_post_rules ] && /etc/firewall.lihas.d/fw_post_rules
	kill -INT $(cat /var/state/firewall-lihasd.pid )
	sleep 1
	firewall-lihasd.pl
        ;;
  restart|force-reload)
        #
        # If the "reload" option is implemented then remove the
        # 'force-reload' alias
        #
        log_daemon_msg "Restarting $DESC" "$NAME"
        do_start
        iptables-restore < $FILE
	[ -x /etc/firewall.lihas.d/fw_post_rules ] && /etc/firewall.lihas.d/fw_post_rules
	kill -INT $(cat /var/state/firewall-lihasd.pid )
	sleep 1
	firewall-lihasd.pl
        ;;
  *)
        #echo "Usage: $SCRIPTNAME {start|stop|restart|reload|force-reload}" >&2
        echo "Usage: $SCRIPTNAME {start|stop|restart|force-reload|test}" >&2
        exit 3
        ;;
esac

exit 0
