
require "Common/define"
require "Common/protocal"
require "Common/functions"
require "3rd/pbc/proto"
Event = require 'events'



Network = {};
local this = Network;

local debugnet = true;
local islogging = false;
local connecttype = 0	--0:login, 1:gate
local AccountAddr = "127.0.0.1"
local AccountPort = 6789
local GateAddr = "127.0.0.1"
local GatePort= 0
local trytimes = 0
local worlduid = 0
local zoneuid = 0
local tokenid = 0
local userid = nil
local beattime = 0
local beatid = 0

--kcp------------------------
local KcpGateAddr = "127.0.0.1"
local KcpGatePort= 40006

function Network.Start() 
    Event.AddListener(Protocal.Connect, this.OnConnect);
    --Event.AddListener(Protocal.Message, this.OnMessage); 
    Event.AddListener(Protocal.Exception, this.OnException); 
    Event.AddListener(Protocal.Disconnect, this.OnDisconnect);

	Event.AddListener("C_S_C_Heart_Beat", this.OnHeartBeat); 
end

--Socket消息--
function Network.OnSocket(key, data)
	if key == Protocal.Connect or key == Protocal.Exception or key == Protocal.Disconnect or key == Protocal.ExceptionKcp then
		if debugnet then
			print(("Network.OnSocket: key=%s"):format(key))
		end
		Event.Brocast(key, data)
	else 
		local data2 = Proto.decode(key, data)
		if debugnet then
			print(("Network.OnSocket: key=%s"):format(key))
			Proto.dump(data2)
		end
		Event.Brocast(key, data2)
	end
end

--当连接建立时--
function Network.OnConnect() 
	print("Network.OnConnect")
	if connecttype == 0 then
		Event.Brocast(Protocal.AccountConnect)
	else
		Event.Brocast(Protocal.GateConnect)
	end
	trytimes = 0
	isreconnecting = false
	beattime = os.time()
end

--异常断线--
function Network.OnException() 
    islogging = false; 
	Network.StopHeartBeat()
	print("OnException:",connecttype, userid)
    if connecttype == 1 then		--网关自动重连1次
		if trytimes < 2 then
			print("开始第"..(trytimes+1).."次重连")
			networkMgr:SendConnect(GateAddr, GatePort)
			trytimes = trytimes + 1
		else
			print("重连失败")
			Event.Brocast(Protocal.NetFailed)
		end
	elseif userid then	--和account server断开后开始连接gate server，因为net是异步通知的，这里相当于回调
		Network.ConnectGate()
	else 
		userid = nil
		Event.Brocast(Protocal.Disconnect, connecttype)
	end
end

--连接中断，或者被踢掉--
function Network.OnDisconnect(_connecttype) 
    islogging = false; 
	Network.StopHeartBeat()
	if trytimes < 1 then
		networkMgr:SendConnect(GateAddr, GatePort)
		trytimes = trytimes + 1
	end
end

--kcp连接--
function Network.ConnectKcp(saddr, port) 
	print("ConnectKcp:", saddr, port)
	KcpGateAddr = saddr
	KcpGatePort = port
	local ok = networkMgr:SendKcpConnect(KcpGateAddr, KcpGatePort)		--同步连接
	if ok then
		Event.Brocast(Protocal.ConnectKcp)		--成功
	else
		Event.Brocast(Protocal.NetFailedKcp)		--失败
	end
end

--向zone发送kcp消息
function Network.SendKcp(name, msg)
	if debugnet then
		print(("Network.SendKcp: name=%s"):format(name))
		Proto.dump(msg)
	end
	local bytes = Proto.encode(name, msg)
	if bytes ~= nil then
		networkMgr:SendKcpMessage(name, zoneuid, bytes)
	end
end


--设置网络连接类型
--_type 0:login, 1:gate
function Network.SetConnectType(_type) 
    connecttype = _type
end

--设置网络相关信息
function Network.SetNetInfo(data) 
	local result = string.split(data.GateAddr, ":")
    GateAddr = result[1]
	GatePort = result[2]
	worlduid = data.WorldId
	tokenid = data.TokenId
	userid = Proto.format64(data.UserId)		--userid是64位整数，这里转为userdata格式的int64
end


--设置zone target
function Network.SetZoneUid(target) 
    zoneuid = target
end

--连接account
function Network.ConnectAccount(host, port) 
	AccountAddr = host
	AccountPort = port
	
	--账号登录，重置相关参数
	trytimes = 0
	worlduid = 0
	zoneuid = 0
	tokenid = 0
	userid = nil
	beattime = 0
	beatid = 0
	isreconnecting = false

	Network.SetConnectType(0)
	networkMgr:SendConnect(AccountAddr, AccountPort)
end

--连接gate
function Network.ConnectGate() 
	Network.SetConnectType(1)
	networkMgr:SendConnect(GateAddr, GatePort)
end

function Network.OnHeartBeat() 
	beattime = os.time()
end

--开始心跳检测
function Network.StartHeartBeat()
	print("开启心跳")
	if beatid ~= 0 then
		timerMgr.del(beatid)
	end
    beatid = timerMgr.add(0, 3000, Network.HeartBeatUpdate, Network)
end

--关闭心跳检测
function Network.StopHeartBeat()
	print("关闭心跳")
	if beatid ~= 0 then
		timerMgr.del(beatid)
	end
    beatid = 0
end


function Network.HeartBeatUpdate()
	Network.SendHeartBeat()
    if os.time() - beattime > 6000 then
		print("Network.HeartBeatUpdate: 心跳超时")
		networkMgr:Close()		--强行断开连接
		Network.StopHeartBeat()

	end
end
--心跳包
function Network.SendHeartBeat()
	if userid == nil then
		logError("Network.SendHeartBeat error, userid is nil")
		return
	end
	local req = {		--C_S_C_Heart_Beat
		TokenId = tokenid,
		UserId = userid,
	}
	Network.SendServer("C_S_C_Heart_Beat", req, worlduid)
end

--发送网络消息
function Network.SendServer(name, msg, target)
	target = target or 0
	if debugnet then
		print(("Network.SendServer: target=%d,name=%s"):format(target, name))
		Proto.dump(msg)
		--Proto.debug(bytes)
	end
	local bytes = Proto.encode(name, msg)
	if bytes ~= nil then
		networkMgr:SendMessage(name, target, bytes)
	end
end

--向world发送消息
function Network.SendWorld(name, msg)
	Network.SendServer(name, msg, worlduid)
end

--向zone发送消息
function Network.SendZone(name, msg)
	Network.SendServer(name, msg, zoneuid)
end

--获取tokenid
function Network.GetTokenId()
	return tokenid
end

--获取userid
function Network.GetUserId()
	return userid
end

--获取world uid
function Network.GetWorld()
	return worlduid
end

--向zone发送消息
function Network.SendZone(name, msg)
	Network.SendServer(name, msg, zoneuid)
end

--卸载网络监听--
function Network.Unload()
    Event.RemoveListener(Protocal.Connect,this.OnConnect);
    --Event.RemoveListener(Protocal.Message, this.OnMessage);
    Event.RemoveListener(Protocal.Exception, this.OnException);
    Event.RemoveListener(Protocal.Disconnect, this.OnDisconnect);
end

-----------------------------------
--测试
function Network.test()
	Event.AddListener(Protocal.AccountConnect, function () 	--连接上账号服务器
		local req = {		--C_A_Login
			AccountName = "test-unity-001",
			Password = "123456",
			Channel = 1,
			LoginType = 1,
			HeadIcon = "",
			Sex = 0,
			NickName = "上海大牛市",
		}
		Network.SendServer("C_A_Login", req)		--发送账号登录消息
	end)
	
	Event.AddListener(Protocal.GateConnect, function (data)		--连接上网关服务器
		local req = {		--LouMiaoLoginGate
			TokenId = Network.GetTokenId(),
			UserId = Network.GetUserId(),
			WorldUid = Network.GetWorld(),
		}
		Network.SendServer("LouMiaoLoginGate", req)		--发送网关登录消息
	end)
	
	Event.AddListener("A_C_Login", function (data)		--账号登录返回
		if data.ErrCode ~= 0 then
			print("login error: "..data.ErrCode)
			return
		end
		Network.SetNetInfo(data)
		networkMgr:Close()		--断开连接，等连接断开后连接gate
	end)
	
	Event.AddListener("LouMiaoLoginGate", function (data)		--网关登录返回
		if data.WorldUid == 0 then
			print("login gate error: "..data.WorldUid)
			return
		end
		local req = {		--C_S_Login
			TokenId = Network.GetTokenId(),
			UserId = Network.GetUserId(),
			VersionCode = "101",
		}
		Network.SendWorld("C_S_Login", req)		--发送world登录消息
	end)
	
	Event.AddListener("S_C_Login", function (data)		--world登录返回
		if data.ErrCode ~= 0 then
			print("login world error: "..data.ErrCode)
			return
		end
		--开始心跳
		Network.StartHeartBeat()
		--
		if data.RoomUid > 0 then		--目前正在游戏中
			Network.SetZoneUid(data.RoomUid)
			--开始请求重连
		end
	end)
	
	Event.AddListener("S_C_AllMails", function (data)		--邮件数据
		local req ={
			RoomDataId = 100010201,
		}
		Network.SendWorld("C_S_EnterRoom", req)		--发送加入房间消息
	end)
	
	Event.AddListener("S_C_LoadRank", function (data)		--排行榜数据
		
	end)
	
	Event.AddListener("S_C_EnterRoom", function (data)		--加入房间
		if data.ErrCode ~= 0 then
			print("enter room failed: "..data.ErrCode)
			return
		end
		Network.SetZoneUid(data.Uid)
		local result = string.split(data.SAddr, ":")
		local ip = result[1]
		local port = result[2]
		Network.ConnectKcp(ip, port)
	end)
	
	Event.AddListener(Protocal.NetFailedKcp, function (data)		--kcp服务器连接失败
		print("无法连接上kcp服务器")
	end)
	
	Event.AddListener(Protocal.ConnectKcp, function (data)		--连接上kcp服务器
	print("kcp服务器连接成功")
		local req = {
			RoomDataId = 100010201, 
			WorldUid = worlduid, 
			UserId = userid,
		}
		Network.SendKcp("C_Z_JoinRoom", req)
	end)
	
	Event.AddListener("Z_C_JoinRoom", function (data)		--加入房间
		if data.ErrCode ~= 0 then
			print("join room failed: "..data.ErrCode)
			return
		end
		local req = {
			Progress = 100,
		}
		Network.SendKcp("C_Z_ReadyGo", req)		--告知加载完成，可以进入游戏
	end)
	
	Event.AddListener("Z_C_ReadyGo", function (data)		--加入房间
		local req = {
			Targets = {1001, 1002, 1003},
		}
		Network.SendKcp("C_Z_Attack", req)		--发动普攻
	end)
	
	Event.AddListener("Z_C_Attack", function (data)		--普攻返回
		local req = {
				Targets = {2001, 2002, 2003},
			}
		Network.SendKcp("C_Z_Spell", req)		--释放技能
	end)
	
	Event.AddListener("Z_C_Spell", function (data)		--释放技能返回
	end)
	
	Event.AddListener(Protocal.ExceptionKcp, function (data)		--和kcp服务断开连接
		print("OnKcpException:")
		if zoneuid > 0 then		--目前正在游戏中
			Network.ConnectKcp(KcpGateAddr, KcpGatePort)
		end
	end)

	Network.ConnectAccount("127.0.0.1", 9789)		--连接账号服务器
end
