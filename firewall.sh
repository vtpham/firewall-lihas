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

# Do NOT "set -e"

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
if getent group www-data >/dev/null 2>&1; then
  mkdir -p "$DATAPATH"
  chgrp www-data $DATAPATH
  chmod g+w $DATAPATH
  touch $DATABASE
  chgrp www-data $DATABASE
  chmod g+w $DATABASE
fi

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
export CONNSTATE
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
  ipset create -exist lihas-moduletest bitmap:ip,mac range 127.0.0.0/24
  if [ $? -eq 0 ]; then
    iptables -A lihas-moduletest -m set --match-set lihas-moduletest src,src 2>/dev/null >&2
    if [ $? -eq 0 ]; then
      HAVE_IPSET=1
    fi
    iptables -F lihas-moduletest 2>/dev/null >&2
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
. $LIBDIR/ipset-setup.sh
. $LIBDIR/iptables-wrapper.sh
. $LIBDIR/feature-portal.sh

echo "Allowing all established Connections"
for chain in INPUT OUTPUT FORWARD; do
  IPT_FILTER ":$chain DROP"
done
for chain in INPUT OUTPUT FORWARD; do
  IPT_FILTER "-A $chain $CONNSTATE ESTABLISHED,RELATED -j ACCEPT"
done
for chain in PREROUTING POSTROUTING OUTPUT; do
  IPT_NAT ":$chain ACCEPT"
done
for chain in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
  IPT_MANGLE ":$chain ACCEPT"
done

for iface in interface-*; do
  iface=${iface#interface-}
  IPT_FILTER ":in-$iface -"
  IPT_FILTER ":out-$iface -"
  IPT_FILTER ":fwd-$iface -"
  IPT_FILTER ":dns-in-$iface -"
  IPT_FILTER ":dns-out-$iface -"
  IPT_FILTER ":dns-fwd-$iface -"

  IPT_NAT ":pre-$iface -"
  IPT_NAT ":post-$iface -"
  IPT_NAT ":dns-pre-$iface -"
  IPT_NAT ":dns-post-$iface -"
done

echo "Setting up IPSEC Spoof Protection"
for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/network-ipsec ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/network-ipsec | sed '/^[ \t]*$/d; /^#/d' |
    while read network; do
      IPT_MANGLE "-A PREROUTING -p esp -j MARK --set-mark 8000/0000"
      IPT_MANGLE "-A PREROUTING -p ah -j MARK --set-mark 8000/0000"
      IPT_FILTER "-A in-$iface -s $network -i $iface -m mark ! --mark 8000/8000 -j $TARGETLOG"
      IPT_FILTER "-A fwd-$iface -s $network -i $iface -m mark ! --mark 8000/8000 -j $TARGETLOG"
      IPT_FILTER "-A in-$iface -s $network -i $iface -m mark ! --mark 8000/8000 -j DROP"
      IPT_FILTER "-A fwd-$iface -s $network -i $iface -m mark ! --mark 8000/8000 -j DROP"
    done
  fi
  IPT_NAT "-A PREROUTING -i $iface -j pre-$iface"
  IPT_NAT "-A POSTROUTING -o $iface -j post-$iface"
done

echo "Policy Routing"
portal_setup

firewall-lihas -f

echo Policy Routing
IPT_MANGLE "-I PREROUTING -j MARK --set-mark 0"
IPT_MANGLE "-I OUTPUT -j MARK --set-mark 0"
for policy in policy-routing-*; do
  policy=${policy#policy-routing-}
  if [ -e policy-routing-$policy/key ]; then
    if ! ip route ls table $policy >/dev/null 2>&1; then
      echo "Please add '$policy' to /etc/iproute2/rt_tables or policy routing won't work. If you don't want policy routing, feel free to delete $CONFIGDIR/policy-routing-$policy" | tee -a $LOGSTARTUP
    fi
    [ -e policy-routing-$policy/comment ] && cat policy-routing-$policy/comment | sed 's/^/ /'
    key=$(cat policy-routing-$policy/key)
    if [ -e policy-routing-$policy/gateway ]; then
      cat policy-routing-$policy/gateway | firewall-lihas -H -P | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
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
        ip rule add fwmark $key pref 9000 table $policy
        ip route flush cache
      done
    fi
  fi
done
for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/policy-routing ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/policy-routing | firewall-lihas -H -P | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport policy; do
      mark=$(cat policy-routing-$policy/key)
      if [ $dport == "0" ]; then
          IPT_MANGLE "-A OUTPUT -s $snet -d $dnet -p $proto -j MARK --set-mark $mark" 
          IPT_MANGLE "-A PREROUTING -s $snet -d $dnet -p $proto -j MARK --set-mark $mark"
      else
          IPT_MANGLE "-A OUTPUT -s $snet -d $dnet -p $proto --dport $dport -j MARK --set-mark $mark"
          IPT_MANGLE "-A PREROUTING -s $snet -d $dnet -p $proto --dport $dport -j MARK --set-mark $mark"
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
      cat $dnet | firewall-lihas -H -P | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read snet dnet proto dport oiface; do
        lihas_ipt_nolog "$snet" "$dnet" "$proto" "$dport" "$oiface"
      done
    else
      echo "$snet doesn't exist"
    fi
  else
    if [ $dport == "0" ]; then
      if [ "ga$oiface" == "ga" ]; then
        IPT_FILTER "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -j DROP"
        IPT_FILTER "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -j DROP"
      else
        IPT_FILTER "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto -o $oiface -j DROP"
      fi
    else
      if [ "ga$oiface" == "ga" ]; then
        if [ $proto == "icmp" ]; then
          IPT_FILTER "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -j DROP"
          IPT_FILTER "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -j DROP"
        else 
          IPT_FILTER "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -j DROP"
          IPT_FILTER "-A in-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -j DROP"
        fi
      else
        if [ $proto == "icmp" ]; then
          IPT_FILTER "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --icmp-type $dport -o $oiface -j DROP"
        else 
          IPT_FILTER "-A fwd-$iface $CONNSTATE NEW -s $snet -d $dnet -p $proto --dport $dport -o $oiface -j DROP"
        fi
      fi
    fi
  fi
}

for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/nolog ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    cat interface-$iface/nolog | firewall-lihas -H -P | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport oiface; do
      lihas_ipt_nolog "$snet" "$dnet" "$proto" "$dport" "$oiface"
    done
  fi
done

lihas_ipt_mark_dhcpd () {
  iface=$1
  IPT_FILTER "-A INPUT -i $iface -p udp --sport 68 --dport 67 -j ACCEPT"
  IPT_FILTER "-A OUTPUT -o $iface -p udp --sport 67 --dport 68 -j ACCEPT"
}
for iface in interface-*; do
  iface=${iface#interface-}
  if [ -e interface-$iface/mark ]; then
    [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
    grep -qwi dhcpd interface-$iface/mark && lihas_ipt_mark_dhcpd "$iface"
  fi
done

for chain in INPUT OUTPUT FORWARD; do
  IPT_FILTER "-A $chain -j $TARGETLOG"
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
	if [ -s "$LOGSTARTUP" ]; then
	  echo
	  echo "********************************************************************************"
	  echo "Potential showstoppers:"
	  cat $LOGSTARTUP
        fi
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
	kill -INT $(cat /var/run/firewall-lihasd.pid )
	ps ax | awk '$5 ~ /^\/usr\/bin\/perl$/ && $6 ~ /firewall-lihasd.pl/ {print $1}' | xargs --no-run-if-empty kill
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
	kill -INT $(cat /var/run/firewall-lihasd.pid )
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
	kill -INT $(cat /var/run/firewall-lihasd.pid )
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
