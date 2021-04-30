using System;
using System.Collections.Generic;

namespace KcpProject
{
    class MessageQueue
    {
        object mMutex;
        List<byte[]> mMessageList;

        public MessageQueue(int capacity = 10)
        {
            mMutex = new object();
            mMessageList = new List<byte[]>(capacity);
        }

        public void Add(byte[] o)
        {
            lock (mMutex)
            {
                mMessageList.Add(o);
            }
        }

        public void MoveTo(List<byte[]> bytesList)
        {
            lock (mMutex)
            {
                bytesList.AddRange(mMessageList);
                mMessageList.Clear();
            }
        }

        public bool Empty()
        {
            lock (mMutex)
            {
                return mMessageList.Count <= 0;
            }
        }

    }
}
