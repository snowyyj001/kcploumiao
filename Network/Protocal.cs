
namespace LuaFramework {
    public class Protocal {
        ///BUILD TABLE
        public const int Connect = 101;     //连接服务器
        public const int Exception = 102;     //异常掉线
        public const int Disconnect = 103;     //正常断线   
        
        public const int ExceptionKcp = 1002;     //异常掉线-kcp
        public const int DisconnectKcp = 1003;     //异常掉线-kcp
    }
}