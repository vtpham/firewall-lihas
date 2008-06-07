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
rm $FILEfilter $FILEnat $FILEmangle

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
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/dnat ]; then
    cat interface-$iface/dnat | sed '/^[ \t]*$/d; /^#/d' |
    while read dnet mnet proto dport ndport; do
      if [ $dport == "0" ]; then
        echo "-A pre-$iface -d $dnet -p $proto --to-destination $mnet" >> $FILEnat
      else
        echo "-A pre-$iface -d $dnet -p $proto --dport $dport -j DNAT --to-destination $mnet:$ndport" >> $FILEnat
      fi
    done
  fi
done

echo "Adding SNAT"
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/snat ]; then
    cat interface-$iface/snat | sed '/^[ \t]*$/d; /^#/d' |
    while read snet mnet proto dport; do
      if [ $dport == "0" ]; then
        echo "-A post-$iface -s $snet -p $proto -j SNAT --to-source $mnet" >> $FILEnat
      else
        echo "-A post-$iface -s $snet -p $proto --dport $dport -j SNAT --to-source $mnet" >> $FILEnat
      fi
    done
  fi
done

echo "Adding MASQUERADE"
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/masquerade ]; then
    cat interface-$iface/masquerade | sed '/^[ \t]*$/d; /^#/d' |
    while read snet mnet proto dport; do
      if [ $dport == "0" ]; then
        echo "-A post-$iface -s $snet -p $proto -j MASQUERADE" >> $FILEnat
      else
        echo "-A post-$iface -s $snet -p $proto --dport $dport -j MASQUERADE" >> $FILEnat
      fi
    done
  fi
done

echo "Adding priviledged Clients"
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/privclients ]; then
    cat interface-$iface/privclients | sed '/^[ \t]*$/d; /^#/d' |
    while read snet dnet proto dport oiface; do
      if [ $dport == "0" ]; then
        if [ "ga$oiface" == "ga" ]; then
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto -j ACCEPT" >> $FILEfilter
          echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto -j ACCEPT" >> $FILEfilter
        else
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto -o $oiface -j ACCEPT" >> $FILEfilter
        fi
      else
        if [ "ga$oiface" == "ga" ]; then
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -j ACCEPT" >> $FILEfilter
          echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto -j ACCEPT" >> $FILEfilter
        else
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -o $oiface -j ACCEPT" >> $FILEfilter
        fi
      fi
    done
  fi
done

echo LOCALHOST
. ./localhost

echo Disable specific logging
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/nolog ]; then
    cat interface-$iface/nolog | sed '/^[ \t]*$/d; /^#/d' |
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
          echo "-A fwd-$iface -m state --state new -s $snet -d $dnet -p $proto --dport $dport -j DROP" >> $FILEfilter
          echo "-A in-$iface -m state --state new -s $snet -d $dnet -p $proto -j DROP" >> $FILEfilter
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


echo Policy Routing
echo "-I PREROUTING -j MARK --set-mark 0 >> $FILEmangle
echo "-I OUTPUT -j MARK --set-mark 0 >> $FILEmangle
for policy in policy-routing-*; do
  policy=${policy#policy-routing-}
  [ -e policy-routing-$policy/comment ] && cat policy-routing-$policy/comment | sed 's/^/ /'
  key=$(cat policy-routing-$policy/key)
  if [ -e policy-routing-$policy/gateway ]; then
    cat policy-routing-$policy/gateway | sed '/^[ \t]*$/d; /^#/d' |
    while read type interface; do
      if [ $type == "PPP" ]; then
        ip route flush table $policy
	ip route ls |
	sed 's/^default.*/default dev '$interface'/' |
	while read a; do
	  ip route add $a table $policy
	done
	while ip rule | grep 'lookup '$policy; do
	  $IP rule del fwmark $key table $policy
	done
	ip rule add fwmark $key table $policy
	ip route flush cache
      else
        echo Non PPP-Policy-Routing is not implemented
      fi
    done
  fi
done
for iface in interface-*; do
  iface=${iface#interface-}
  [ -e interface-$iface/comment ] && cat interface-$iface/comment | sed 's/^/ /'
  if [ -e interface-$iface/policy-routing ]; then
    cat interface-$iface/policy-routing | sed '/^[ \t]*$/d; /^#/d' |
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

echo *filter > $FILE
cat $FILEfilter >> $FILE
echo COMMIT >> $FILE
echo *mangle >> $FILE
cat $FILEmangle >> $FILE
echo COMMIT >> $FILE
echo *nat >> $FILE
cat $FILEnat >> $FILE
echo COMMIT >> $FILE

iptables-restore < $FILE
}

do_stop () {
  iptables-restore < /etc/firewall.lihas.d/iptables-accept
}




case "$1" in
  start)
	[ "$VERBOSE" != no ] && log_daemon_msg "Starting $DESC" "$NAME"
	do_start
	case "$?" in
		0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  stop)
	[ "$VERBOSE" != no ] && log_daemon_msg "Stopping $DESC" "$NAME"
	do_stop
	case "$?" in
		0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  reload|force-reload)
	#
	# If do_reload() is not implemented then leave this commented out
	# and leave 'force-reload' as an alias for 'restart'.
	#
	log_daemon_msg "Reloading $DESC" "$NAME"
	do_start
	log_end_msg $?
	;;
  restart|force-reload)
	#
	# If the "reload" option is implemented then remove the
	# 'force-reload' alias
	#
	log_daemon_msg "Restarting $DESC" "$NAME"
	do_stop
	case "$?" in
	  0|1)
		do_start
		case "$?" in
			0) log_end_msg 0 ;;
			1) log_end_msg 1 ;; # Old process is still running
			*) log_end_msg 1 ;; # Failed to start
		esac
		;;
	  *)
	  	# Failed to stop
		log_end_msg 1
		;;
	esac
	;;
  *)
	#echo "Usage: $SCRIPTNAME {start|stop|restart|reload|force-reload}" >&2
	echo "Usage: $SCRIPTNAME {start|stop|restart|force-reload}" >&2
	exit 3
	;;
esac


