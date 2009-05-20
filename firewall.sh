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
# $Id: firewall.sh,v 1.33 2008/11/05 11:58:31 are Exp are $
#

# Do NOT "set -e"

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DESC="LiHAS Firewall"
NAME=firewall
DAEMON=/bin/true
SCRIPTNAME=/etc/init.d/$NAME

# Exit if the package is not installed
[ -x "$DAEMON" ] || exit 0

# Read configuration variable file if it is present
[ -r /etc/default/$NAME ] && . /etc/default/$NAME

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

[ -d /etc/firewall.lihas.d ] && cd /etc/firewall.lihas.d

FILE=/tmp/iptables
FILEfilter=/tmp/iptables-filter
FILEnat=/tmp/iptables-nat
FILEmangle=/tmp/iptables-mangle
rm $FILE $FILEfilter $FILEnat $FILEmangle

if [ `uname -m` == mips ]; then
  LOGTARGET=ULOG
else
  LOGTARGET=LOG
fi

. lib/helper-dns.sh
. lib/helper-group.sh
. lib/lihas_ipt_reject.sh

echo "Allowing all established Connections"
for chain in INPUT OUTPUT FORWARD; do
  echo ":$chain DROP" >> $FILEfilter
done
for chain in INPUT OUTPUT FORWARD; do
  echo "-A $chain -m state --state ESTABLISHED,RELATED -j ACCEPT" >> $FILEfilter
done
for chain in PREROUTING POSTROUTING OUTPUT; do
  echo ":$chain ACCEPT" >> $FILEnat
done
for chain in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
  echo ":$chain ACCEPT" >> $FILEmangle
done

echo "Setting up Chains"
for iface in interface-*; do
  iface=${iface#interface-}
  echo ":in-$iface -" >> $FILEfilter
  echo ":out-$iface -" >> $FILEfilter
  echo ":fwd-$iface -" >> $FILEfilter

  echo ":pre-$iface -" >> $FILEnat
  echo ":post-$iface -" >> $FILEnat
done

for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/network ]; then
    cat interface-$iface/network | sed '/^[ \t]*$/d; /^#/d' |
    while read network; do
      echo "-A INPUT -s $network -i $iface -j in-$iface" >> $FILEfilter
      echo "-A OUTPUT -d $network -o $iface -j out-$iface" >> $FILEfilter
      echo "-A FORWARD -s $network -i $iface -j fwd-$iface" >> $FILEfilter
    done
  else
    echo "WARNING: Interface $iface has no network file"
  fi
  echo "-A PREROUTING -i $iface -j pre-$iface" >> $FILEnat
  echo "-A POSTROUTING -o $iface -j post-$iface" >> $FILEnat
done

echo "Loopback Interface is fine"
echo "-A OUTPUT	-j ACCEPT -o lo" >> $FILEfilter
echo "-A INPUT	-j ACCEPT -i lo" >> $FILEfilter

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
        echo "-A pre-$iface -s $mnet -p $proto -j ACCEPT" >> $FILEnat
      else
        if [ $proto == "icmp" ]; then
          echo "-A pre-$iface -s $mnet -p $proto --icmp-type $dport -j ACCEPT" >> $outfile
        else 
          echo "-A pre-$iface -s $mnet -p $proto --dport $dport -j ACCEPT" >> $outfile
        fi
      fi
    else
      if [ $dport == "0" ]; then
        echo "-A pre-$iface -d $dnet -p $proto -j DNAT --to-destination $mnet" >> $FILEnat
      else
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
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/dnat ]; then
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
        echo "-A post-$iface -s $snet -p $proto -j ACCEPT" >> $FILEnat
      else
        if [ $proto == "icmp" ]; then
          echo "-A post-$iface -s $snet -p $proto --icmp-type  $dport -j ACCEPT" >> $outfile
        else
          echo "-A post-$iface -s $snet -p $proto --dport $dport -j ACCEPT" >> $outfile
        fi
      fi
    else
      if [ $dport == "0" ]; then
        echo "-A post-$iface -s $snet -p $proto -j SNAT --to-source $mnet" >> $FILEnat
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
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/snat ]; then
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
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/masquerade ]; then
    cat interface-$iface/masquerade | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet mnet proto dport; do
      lihas_ipt_masquerade "$FILEnat" "$snet" "$mnet" "$proto" "$dport"
    done
  fi
done

echo "Rejecting extra Clients"
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/reject ]; then
    cat interface-$iface/reject | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport oiface; do
      lihas_ipt_rejectclients "$FILEfilter" "$snet" "$dnet" "$proto" "$dport" "$oiface"
    done
  fi
done

echo "Adding priviledged Clients"
lihas_ipt_privclients () {
  outfile=$1
  snet=$2
  dnet=$3
  proto=$4
  dport=$5
  oiface=$6
  if [ "$snet" == "include" ]; then
    if [ -e "$dnet" ]; then
      cat $dnet | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read snet dnet proto dport oiface; do
        lihas_ipt_privclients "$outfile" "$snet" "$dnet" "$proto" "$dport" "$oiface"
      done
    else
      echo "$snet doesn't exist"
    fi
  else
    if [ $dport == "0" ]; then
      if [ "ga$oiface" == "ga" ]; then
        echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto -j ACCEPT" >> $outfile
        echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto -j ACCEPT" >> $outfile
      else
        echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto -o $oiface -j ACCEPT" >> $outfile
      fi
    else
      if [ "ga$oiface" == "ga" ]; then
        if [ $proto == "icmp" ]; then
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --icmp-type $dport -j ACCEPT" >> $outfile
          echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto --icmp-type $dport -j ACCEPT" >> $outfile
        else 
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -j ACCEPT" >> $outfile
          echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -j ACCEPT" >> $outfile
        fi
      else
        if [ $proto == "icmp" ]; then
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --icmp-type $dport -o $oiface -j ACCEPT" >> $outfile
        else 
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -o $oiface -j ACCEPT" >> $outfile
        fi
      fi
    fi
  fi
}

for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/privclients ]; then
    cat interface-$iface/privclients | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport oiface; do
      lihas_ipt_privclients "$FILEfilter" "$snet" "$dnet" "$proto" "$dport" "$oiface"
    done
  fi
done


echo Policy Routing
echo "-I PREROUTING -j MARK --set-mark 0" >> $FILEmangle
echo "-I OUTPUT -j MARK --set-mark 0" >> $FILEmangle
for policy in policy-routing-*; do
  policy=${policy#policy-routing-}
  [ -e policy-routing-$policy/comment ] && cat policy-routing-$policy/comment | sed 's/^/ /'
  if [ -e policy-routing-$policy/key ]; then
    key=$(cat policy-routing-$policy/key)
    if [ -e policy-routing-$policy/gateway ]; then
      cat policy-routing-$policy/gateway | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
      while read type interface; do
        if [ $type == "PPP" ]; then
          ip route flush table $policy
        ip route ls |
        sed '/^default.*/d' |
        while read a; do
          ip route add $a table $policy
        done
	ip route add default dev $interface table $policy
        while ip rule | grep 'lookup '$policy; do
          ip rule del fwmark $key table $policy
        done
        ip rule add fwmark $key table $policy
        ip route flush cache
        else
          echo Non PPP-Policy-Routing is not implemented
	fi
      done
    fi
  fi
done
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/policy-routing ]; then
    cat interface-$iface/policy-routing | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport policy; do
      mark=$(cat policy-routing-$policy/key)
      if [ $dport == "0" ]; then
          echo "-A OUTPUT -s $snet -d $dnet -p $proto -j MARK --set-mark $mark" >> $FILEmangle
          echo "-A PREROUTING -s $snet -d $dnet -p $proto -j MARK --set-mark $mark" >> $FILEmangle
      else
          echo "-A OUTPUT -s $snet -d $dnet -p $proto --dport $dport -j MARK --set-mark $mark" >> $FILEmangle
          echo "-A PREROUTING -s $snet -d $dnet -p $proto --dport $dport -j MARK --set-mark $mark" >> $FILEmangle
      fi
    done
  fi
done

echo LOCALHOST
. ./localhost

# Disable specific logging
echo "Disable some logging"
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/nolog ]; then
    cat interface-$iface/nolog | helper_hostgroup | helper_portgroup | helper_dns | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport oiface; do
      if [ $dport == "0" ]; then
        if [ "ga$oiface" == "ga" ]; then
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto -j DROP" >> $FILEfilter
          echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto -j DROP" >> $FILEfilter
        else
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto -o $oiface -j DROP" >> $FILEfilter
        fi
      else
        if [ "ga$oiface" == "ga" ]; then
          if [ $proto == "icmp" ]; then
            echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --icmp-type $dport -o $oiface -j ACCEPT" >> $FILEfilter
            echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --icmp-type $dport -j DROP" >> $FILEfilter
            echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto --icmp-type $dport -j DROP" >> $FILEfilter
          else 
            echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -j DROP" >> $FILEfilter
            echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -j DROP" >> $FILEfilter
	  fi
        else
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -o $oiface -j DROP" >> $FILEfilter
        fi
      fi
    done
  fi
done

for chain in INPUT OUTPUT FORWARD; do
  echo "-A $chain -j LOG" >> $FILEfilter
done


echo *filter > $FILE
cat $FILEfilter >> $FILE
echo COMMIT >> $FILE
echo *mangle >> $FILE
cat $FILEmangle >> $FILE
echo COMMIT >> $FILE
echo *nat >> $FILE
cat $FILEnat >> $FILE
echo COMMIT >> $FILE

}

do_stop () {
  iptables-restore < /etc/firewall.lihas.d/iptables-accept
}

FILE=/tmp/iptables

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
        ;;
  stop)
        [ "$VERBOSE" != no ] && log_daemon_msg "Stopping $DESC" "$NAME"
        do_stop
        ;;
  reload|restart|force-reload)
        #
        # If do_reload() is not implemented then leave this commented out
        # and leave 'force-reload' as an alias for 'restart'.
        #
        log_daemon_msg "Reloading $DESC" "$NAME"
        do_start
        iptables-restore < $FILE
	[ -x /etc/firewall.lihas.d/fw_post_rules ] && /etc/firewall.lihas.d/fw_post_rules
        ;;
  *)
        #echo "Usage: $SCRIPTNAME {start|stop|restart|reload|force-reload}" >&2
        echo "Usage: $SCRIPTNAME {start|stop|restart|force-reload}" >&2
        exit 3
        ;;
esac

exit 0
