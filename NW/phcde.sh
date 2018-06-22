#!/bin/sh
#
# phcde.sh              : Ping Host and Check DNS Entry
#
#  @(#) phcde.sh : Ping Host and Check DNS Entry
#  
##############################################################################
#
# Need host command. (!= khost/knot host command)
#

ICMP_WAIT=1
[ `id -u` -eq 0 ] && ICMP_WAIT=0.01

[ -z "$(which host)" ] && echo -n "Error: host command not found" && exit 1
[ ${#} -ne 2 ] && echo -n "Error!. Need start addr, and end octet" && exit 1

addr1=$(echo ${1} | cut -d "." -f 1)
addr2=$(echo ${1} | cut -d "." -f 2)
addr3=$(echo ${1} | cut -d "." -f 3)
start=$(echo ${1} | cut -d "." -f 4)
end=${2}

##### Address check.
for i in ${addr1} ${addr2} ${addr3} ${start} ${end}; do
  case ${i} in
    ''|*[!0-9]*)
      echo "Error. Use IPv4 addresses."
      exit 1
    ;;
    *)
      :
    ;;
  esac
  [ ${i} -gt 255 ] && echo "Error. Use IPv4 Address." && exit 1
done
  [ ${start} -gt ${end} ] && echo "Error. End is smaller then start." && exit 1

echo "from ${addr1}.${addr2}.${addr3}.${start} to ${addr1}.${addr2}.${addr3}.${end}"

for i in `seq ${start} 1 ${end}`; do
  echo -n "${addr1}.${addr2}.${addr3}.${i}"
  #sudo ping -c 3 -i ${ICMP_WAIT} ${addr1}.${addr2}.${addr3}.${i} > /dev/null
  ping -c 3 -i ${ICMP_WAIT} ${addr1}.${addr2}.${addr3}.${i} > /dev/null
  if [ ${?} -eq 0 ]; then
    echo -n " : ok"
  else
    echo -n " : ng"
  fi
  RET=$(host -W 1 -t PTR ${i}.${addr3}.${addr2}.${addr1}.in-addr.arpa)
  echo ${RET} | grep "NXDOMAIN"> /dev/null
  if [ $? -eq 0 ]; then
    echo -n " : NXDOMAIN"
  else
    P_HOST=$( echo ${RET} | cut -d " " -f 5 )
    RET=$(host -W 1 -t A ${P_HOST})
    echo ${RET} | grep "NXDOMAIN"> /dev/null
    if [ $? -eq 0 ]; then
      P_PTR="NXDOMAIN"
    else
      P_PTR=$( echo ${RET} | cut -d " " -f 4 )
    fi
    echo -n " : ${P_HOST} / ${P_PTR}"
    if [ "${P_PTR}" == "${addr1}.${addr2}.${addr3}.${i}" ]; then
      echo -n " : OK!"
    else
      echo -n " : NG mismatch!"
    fi
  fi  
  echo
done
