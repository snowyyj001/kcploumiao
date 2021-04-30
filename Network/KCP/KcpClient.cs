using UnityEngine;
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Collections;
using System.Collections.Generic;
using LuaFramework;
using LuaInterface;
using System.Threading;

namespace KcpProject
{
    public enum DisType
    {
        Exception,
        Disconnect,
    }

   
    public class KcpClient
    {
        const int KCPWinSedSize = 256;  //最大发送窗口，默认为32
        const int KCPWinRevSize = 256;  //最大接收窗口，默认为32


        private UDPSession client = null;
        private MemoryStream memStream;
        private BinaryReader reader;

        private volatile bool mUpdateWork = false;
        private Thread mReceiveThread = null;
        private MessageQueue mSendMsgQueue = null;

        private const int MAX_READ = 1024 * 64;
        private byte[] byteBuffer = new byte[MAX_READ];

        public static KcpClient mInstance;
        public static KcpClient Instance
        {
            get
            {
                if (mInstance == null)
                {
                    mInstance = new KcpClient();
                }
                return mInstance;
            }
        }

        // Use this for initialization
        public KcpClient()
        {
            
        }

        /// <summary>
        /// 注册代理
        /// </summary>
        public void OnRegister()
        {
            memStream = new MemoryStream();
            reader = new BinaryReader(memStream);
            mSendMsgQueue = new MessageQueue();
        }

        /// <summary>
        /// 移除代理
        /// </summary>
        public void OnRemove()
        {
            if (reader != null)
            {
                reader.Close();
                reader = null;
            }
            if (memStream != null)
            {
                memStream.Close();
                memStream = null;
            }
            mSendMsgQueue = null;
        }

        /// <summary>
        /// 连接服务器
        /// </summary>
        public bool ConnectServer(string host, int port)
        {
            client = null;
            try
            {
                IPAddress[] address = Dns.GetHostAddresses(host);
                if (address.Length == 0)
                {
                    Debug.LogError("host invalid");
                    return false;
                }
                client = new UDPSession();
                client.AckNoDelay = true;
                client.WriteDelay = false;
                client.Connect(host, port);
                if (client.IsConnected)
                {
                    client.SetWindowSize(KCPWinSedSize, KCPWinRevSize);
                    OnConnect();
                    return true;
                }
            }
            catch (Exception e)
            {
                Close(); Debug.LogError(e.Message);
            }
            return false;
        }
        private void WorkThread(object o)
        {
            int recvBytes = 0;
            List<byte[]> workList = new List<byte[]>(10);
            while (mUpdateWork)
            {
                if (client == null)
                {
                    break;
                }

                client.Update();
                
                if (!mSendMsgQueue.Empty())
                {
                    mSendMsgQueue.MoveTo(workList);
                    int k = 0;
                    while (k < workList.Count)
                    {
                        var msgObj = workList[k];
                        var sn = WriteMessage(msgObj);
                        if(sn == 0)
                        {
                            break;
                        }
                        k++;
                    }
                    while (k < workList.Count)
                    {
                        mSendMsgQueue.Add(workList[k]);
                        k++;
                    }
                    workList.Clear();
                }

                var n = client.Recv(byteBuffer, 0, byteBuffer.Length);
                if (n == 0)
                {
                    Thread.Sleep(10);
                    continue;
                }
                else if (n < 0)
                {
                    Debug.LogError("Receive Kcp Message failed: n = " + n);
                    OnDisconnected(DisType.Exception, "Receive Kcp Message failed");
                    break;
                }
                else
                {
                    recvBytes += n;
                    OnReceive(byteBuffer, n);
                }
            }
            
        }

        /// <summary>
        /// 连接上服务器
        /// </summary>
        void OnConnect()
        {
            OnRegister();
            if (mReceiveThread == null)
            {
                mReceiveThread = new Thread(WorkThread);
                mUpdateWork = true;
                mReceiveThread.Start(null);
            }
        }

        /// <summary>
        /// 写数据
        /// </summary>
        int WriteMessage(byte[] message)
        {
            var sent = client.Send(message, 0, message.Length);
            return sent;
        }

        /// <summary>
        /// 丢失链接
        /// </summary>
        void OnDisconnected(DisType dis, string msg)
        {
            Close();   //关掉客户端链接
            int protocal = dis == DisType.Exception ?
            Protocal.ExceptionKcp : Protocal.DisconnectKcp;

            NetworkManager.AddEvent(protocal.ToString(), new LuaByteBuffer(new byte[] { }));
            Debug.LogWarning("Connection was closed by the server:>" + msg + " Distype:>" + dis);
        }

        /// <summary>
        /// 打印字节
        /// </summary>
        /// <param name="bytes"></param>
        void PrintBytes()
        {
            string returnStr = string.Empty;
            for (int i = 0; i < byteBuffer.Length; i++)
            {
                returnStr += byteBuffer[i].ToString("X2");
            }
            Debug.LogError(returnStr);
        }

        /// <summary>
        /// 接收到消息
        /// </summary>
        void OnReceive(byte[] bytes, int length)
        {
            //memStream.Seek(0, SeekOrigin.End); //这里不应该重置的
           // memStream.Write(bytes, 0, length);
            memStream.Write(bytes, (int)memStream.Length, length);
            //Debug.Log(bytes);
            //Reset to beginning
            memStream.Seek(0, SeekOrigin.Begin);
            while (RemainingBytes() > 8)
            {
                Int32 messageLen = IPAddress.NetworkToHostOrder(reader.ReadInt32());
                if (RemainingBytes() >= messageLen - 4)
                {
                    MemoryStream ms = new MemoryStream();
                    BinaryWriter writer = new BinaryWriter(ms);
                    writer.Write(reader.ReadBytes(messageLen - 4));
                    ms.Seek(0, SeekOrigin.Begin);

                    OnReceivedMessage(ms);
                }
                else
                {
                    //Back up the position four bytes
                    memStream.Position = memStream.Position - 4;
                    break;
                }
            }
            //Create a new stream with any leftover bytes
            byte[] leftover = reader.ReadBytes((int)RemainingBytes());
            memStream.SetLength(0);     //Clear
            memStream.Write(leftover, 0, leftover.Length);
        }

        /// <summary>
        /// 剩余的字节
        /// </summary>
        private long RemainingBytes()
        {
            return memStream.Length - memStream.Position;
        }

        /// <summary>
        /// 接收到消息
        /// </summary>
        /// <param name="ms"></param>
        void OnReceivedMessage(MemoryStream ms)
        {
            BinaryReader r = new BinaryReader(ms);
            byte[] message = r.ReadBytes((int)(ms.Length - ms.Position));
            //int msglen = message.Length;
            LuaFramework.ByteBuffer buffer = new LuaFramework.ByteBuffer(message);
            int uid = buffer.ReadShort();   //这个字段对客户端无意义
            short nameLen = IPAddress.NetworkToHostOrder((short)buffer.ReadShort());

            string name = System.Text.Encoding.UTF8.GetString(buffer.ReadBytes(nameLen));
            LuaByteBuffer lb = buffer.ReadBuffer((int)(ms.Length - 4 - nameLen));

            NetworkManager.AddEvent(name, lb);
        }


        /// <summary>
        /// 会话发送
        /// </summary>
        void SessionSend(byte[] bytes)
        {
            mSendMsgQueue.Add(bytes);
        }

        /// <summary>
        /// 关闭链接
        /// </summary>
        public void Close()
        {
            if (mReceiveThread != null)
            {
                mUpdateWork = false;
                mReceiveThread.Join();
                mReceiveThread = null;
            }
            if (client != null)
            {
                if (client.IsConnected) client.Close();
                client = null;
                Array.Clear(byteBuffer, 0, byteBuffer.Length);   //清空数组
            }
            OnRemove();
        }

        /// <summary>
        /// 发送连接请求
        /// </summary>
        public void SendConnect()
        {
            ConnectServer(AppConst.SocketAddress, AppConst.SocketPort);
        }

        /// <summary>
        /// 发送消息
        /// </summary>
        public void SendMessage(LuaFramework.ByteBuffer buffer)
        {
            SessionSend(buffer.ToBytes());
            buffer.Close();
        }
    }
}
