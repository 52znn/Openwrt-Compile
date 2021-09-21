#!/bin/sh

# 检查传入参数
[ -z "$username" ] && write_log 14 "Configuration error! [User name] cannot be empty"
[ -z "$password" ] && write_log 14 "Configuration error! [Password] cannot be empty"

# 检查外部调用工具
[ -n "$CURL_SSL" ] || write_log 13 "Dnspod communication require cURL with SSL support. Please install"
[ -n "$CURL_PROXY" ] || write_log 13 "cURL: libcurl compiled without Proxy support"
command -v openssl >/dev/null 2>&1 || write_log 13 "Openssl-util support is required to use Dnspod API, please install first"

# 变量声明
local __APIHOST __HOST __DOMAIN __TYPE __CMDBASE __POST __POST1 __POST2 __POST3 __RECIP __RECID __TTL __CNT __A
__APIHOST=dnspod.tencentcloudapi.com

# 从 $domain 分离主机和域名
[ "${domain:0:2}" = "@." ] && domain="${domain/./}" # 主域名处理
[ "$domain" = "${domain/@/}" ] && domain="${domain/./@}" # 未找到分隔符，兼容常用域名格式
__HOST="${domain%%@*}"
__DOMAIN="${domain#*@}"
[ -z "$__HOST" -o "$__HOST" = "$__DOMAIN" ] && __HOST=@

# 设置记录类型
[ $use_ipv6 = 0 ] && __TYPE=A || __TYPE=AAAA

# 构造基本通信命令
build_command(){
	__CMDBASE="$CURL -Ss"
	# 绑定用于通信的主机/IP
	if [ -n "$bind_network" ];then
		local __DEVICE
		network_get_physdev __DEVICE $bind_network || write_log 13 "Can not detect local device using 'network_get_physdev $bind_network' - Error: '$?'"
		write_log 7 "Force communication via device '$__DEVICE'"
		__CMDBASE="$__CMDBASE --interface $__DEVICE"
	fi
	# 强制设定IP版本
	if [ $force_ipversion = 1 ];then
		[ $use_ipv6 = 0 ] && __CMDBASE="$__CMDBASE -4" || __CMDBASE="$__CMDBASE -6"
	fi
	# 设置CA证书参数
	if [ $use_https = 1 ];then
		if [ "$cacert" = IGNORE ];then
			__CMDBASE="$__CMDBASE --insecure"
		elif [ -f "$cacert" ];then
			__CMDBASE="$__CMDBASE --cacert $cacert"
		elif [ -d "$cacert" ];then
			__CMDBASE="$__CMDBASE --capath $cacert"
		elif [ -n "$cacert" ];then
			write_log 14 "No valid certificate(s) found at '$cacert' for HTTPS communication"
		fi
	fi
	# 如果没有设置，禁用代理 (这可能是 .wgetrc 或环境设置错误)
	[ -z "$proxy" ] && __CMDBASE="$__CMDBASE --noproxy '*'"
	__CMDBASE="$__CMDBASE -d"
}

# 用于生成签名
HMAC(){
	echo -en $1 | openssl dgst -sha256 -mac HMAC -macopt hexkey:$2 | awk '{print $2}'
}

# 生成链接
URL(){
	local __DATE __STAMP A B C D E 
	__DATE=$(date -u +%Y-%m-%d)
	__STAMP=$(date +%s)
	A="POST\n/\n\ncontent-type:application/json\nhost:$__APIHOST\n\ncontent-type;host\n$(echo -n $1 | sha256sum | awk '{print $1}')"
	B="TC3-HMAC-SHA256\n$__STAMP\n$__DATE/dnspod/tc3_request\n$(echo -en $A | sha256sum | awk '{print $1}')"
	C=$(HMAC tc3_request $(HMAC dnspod $(echo -n $__DATE | openssl dgst -sha256 -hmac TC3$password | awk '{print $2}')))
	D="TC3-HMAC-SHA256 Credential=$username/$__DATE/dnspod/tc3_request,SignedHeaders=content-type;host,Signature=$(HMAC $B $C)"
	E="-H 'Authorization: $D' -H 'X-TC-Timestamp: $__STAMP' -H 'Content-Type: application/json' -H 'X-TC-Version: 2021-03-23' -H 'X-TC-Language: zh-CN'"
	__A="$__CMDBASE '$1' $E -H 'X-TC-Action: $2' https://$__APIHOST"
}

# 用于Dnspod API的通信函数
dnspod_transfer(){
	__CNT=0
	case "$1" in
		1)URL $__POST1 DescribeRecordList;;
		2)URL $__POST2 CreateRecord;;
		3)__POST3="${__POST2%\}*},\"RecordId\":$__RECID,\"TTL\":$__TTL}";URL $__POST3 ModifyRecord;;
	esac

	write_log 7 "#> $(echo -e "$__A" | sed "s/默认/Default/g")"
	while ! __TMP=`eval $__A 2>&1`;do
		write_log 3 "[$__TMP]"
		if [ $VERBOSE -gt 1 ];then
			write_log 4 "Transfer failed - detailed mode: $VERBOSE - Do not try again after an error"
			return 1
		fi
		__CNT=$(( $__CNT + 1 ))
		[ $retry_count -gt 0 -a $__CNT -gt $retry_count ] && write_log 14 "Transfer failed after $retry_count retries"
		write_log 4 "Transfer failed - $__CNT Try again in $RETRY_SECONDS seconds"
		sleep $RETRY_SECONDS &
		PID_SLEEP=$!
		wait $PID_SLEEP
		PID_SLEEP=0
	done
	__ERR=`jsonfilter -s "$__TMP" -e "@.Response.Error.Code"`
	[ ! $__ERR -o $__ERR = ResourceNotFound.NoDataOfRecord ] && return 0
	[ $__TMP = AuthFailure.SignatureExpire ] && printf "%s\n" " $(date +%H%M%S)       : 时间戳错误,2秒后重试" >> $LOGFILE && return 1
	__TMP=`jsonfilter -s "$__TMP" -e "@.Response.Error.Message"`
	local A="$(date +%H%M%S) ERROR : [$__TMP] - 终止进程"
	logger -p user.err -t ddns-scripts[$$] $SECTION_ID: ${A:15}
	printf "%s\n" " $A" >> $LOGFILE
	exit 1
}

# 添加解析记录
add_domain(){
	while ! dnspod_transfer 2;do sleep 2;done
	printf "%s\n" " $(date +%H%M%S)       : 添加解析记录成功: [$([ "$__HOST" = @ ] || echo $__HOST.)$__DOMAIN],[IP:$__IP]" >> $LOGFILE
	return 0
}

# 修改解析记录
update_domain(){
	while ! dnspod_transfer 3;do sleep 2;done
	printf "%s\n" " $(date +%H%M%S)       : 修改解析记录成功: [$([ "$__HOST" = @ ] || echo $__HOST.)$__DOMAIN],[IP:$__IP],[TTL:$__TTL]" >> $LOGFILE
	return 0
}

# 获取域名解析记录
describe_domain(){
	ret=0
	__POST="{\"Domain\":\"$__DOMAIN\""
	__POST1="$__POST,\"Subdomain\":\"$__HOST\"}"
	__POST2="$__POST,\"SubDomain\":\"$__HOST\",\"Value\":\"$__IP\",\"RecordType\":\"$__TYPE\",\"RecordLine\":\"默认\"}"
	while ! dnspod_transfer 1;do sleep 2;done
	__TMP=`jsonfilter -s "$__TMP" -e "@.Response.RecordList[@.Type='$__TYPE' && @.Line='默认']"`
	if [ -z "$__TMP" ];then
		printf "%s\n" " $(date +%H%M%S)       : 解析记录不存在: [$([ "$__HOST" = @ ] || echo $__HOST.)$__DOMAIN]" >> $LOGFILE
		ret=1
	else
		__RECIP=`jsonfilter -s "$__TMP" -e "@.Value"`
		if [ "$__RECIP" != "$__IP" ];then
			__RECID=`jsonfilter -s "$__TMP" -e "@.RecordId"`
			__TTL=`jsonfilter -s "$__TMP" -e "@.TTL"`
			printf "%s\n" " $(date +%H%M%S)       : 解析记录需要更新: [解析记录IP:$__RECIP] [本地IP:$__IP]" >> $LOGFILE
			ret=2
		fi
	fi
}

build_command
describe_domain
if [ $ret = 1 ];then
	sleep 3
	add_domain
elif [ $ret = 2 ];then
	sleep 3
	update_domain
else
	printf "%s\n" " $(date +%H%M%S)       : 解析记录不需要更新: [解析记录IP:$__RECIP] [本地IP:$__IP]" >> $LOGFILE
fi

return 0
