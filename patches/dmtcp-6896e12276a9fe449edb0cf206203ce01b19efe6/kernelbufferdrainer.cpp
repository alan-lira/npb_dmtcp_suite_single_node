/****************************************************************************
 *   Copyright (C) 2006-2010 by Jason Ansel, Kapil Arya, and Gene Cooperman *
 *   jansel@csail.mit.edu, kapil@ccs.neu.edu, gene@ccs.neu.edu              *
 *                                                                          *
 *   This file is part of the dmtcp/src module of DMTCP (DMTCP:dmtcp/src).  *
 *                                                                          *
 *  DMTCP:dmtcp/src is free software: you can redistribute it and/or        *
 *  modify it under the terms of the GNU Lesser General Public License as   *
 *  published by the Free Software Foundation, either version 3 of the      *
 *  License, or (at your option) any later version.                         *
 *                                                                          *
 *  DMTCP:dmtcp/src is distributed in the hope that it will be useful,      *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of          *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           *
 *  GNU Lesser General Public License for more details.                     *
 *                                                                          *
 *  You should have received a copy of the GNU Lesser General Public        *
 *  License along with DMTCP:dmtcp/src.  If not, see                        *
 *  <http://www.gnu.org/licenses/>.                                         *
 ****************************************************************************/

#include "kernelbufferdrainer.h"
#include "../jalib/jassert.h"
#include "../jalib/jbuffer.h"
#include "connectionlist.h"
#include "connectionmessage.h"
#include "socketwrappers.h"
#include "util.h"
#include <errno.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

#define SOCKET_DRAIN_MAGIC_COOKIE_STR "[dmtcp{v0<DRAIN!"

using namespace dmtcp;

const char theMagicDrainCookie[] = SOCKET_DRAIN_MAGIC_COOKIE_STR;

// Reader for SOCK_SEQPACKET that preserves message boundaries by reading
// exactly one frame per readOnce() using FIONREAD to determine size.
class JSeqpacketReader : public jalib::JReaderInterface
{
  public:
    JSeqpacketReader(jalib::JSocket sock)
      : jalib::JReaderInterface(sock), _hadError(false) {}

    bool readOnce() override
    {
      if (!_frame.empty()) {
        return true;
      }
      int fd = _sock.sockfd();
      // First peek the next message length without removing it from the queue
      struct msghdr peekMsg;
      memset(&peekMsg, 0, sizeof(peekMsg));
      // Use a 1-byte iovec; MSG_TRUNC returns the full packet length.
      char dummy;
      struct iovec iovPeek = { .iov_base = &dummy, .iov_len = 1 };
      peekMsg.msg_iov = &iovPeek;
      peekMsg.msg_iovlen = 1;
      ssize_t needed = ::recvmsg(fd, &peekMsg, MSG_PEEK | MSG_TRUNC);
      if (needed <= 0) {
        if (errno != EAGAIN && errno != EINTR) {
          _hadError = true;
        }
        return false;
      }
      _frame.resize((size_t)needed);
      struct iovec iov;
      iov.iov_base = _frame.data();
      iov.iov_len = _frame.size();
      struct msghdr readMsg;
      memset(&readMsg, 0, sizeof(readMsg));
      readMsg.msg_iov = &iov;
      readMsg.msg_iovlen = 1;
      ssize_t got = ::recvmsg(fd, &readMsg, 0);
      if (got <= 0) {
        if (errno != EAGAIN && errno != EINTR) {
          _hadError = true;
        }
        _frame.clear();
        return false;
      }
      _frame.resize((size_t)got);
      return true;
    }

    bool hadError() const override { return _hadError || !_sock.isValid(); }

    void reset() override { _frame.clear(); }

    bool ready() const override { return !_frame.empty(); }

    const char *buffer() const override { return _frame.empty() ? NULL : _frame.data(); }

    int bytesRead() const override { return (int)_frame.size(); }

  private:
    dmtcp::vector<char> _frame;
    bool _hadError;
};

void
scaleSendBuffers(int fd, double factor)
{
  int size;
  unsigned len = sizeof(size);

  JASSERT(getsockopt(fd, SOL_SOCKET, SO_SNDBUF, (void *)&size, &len) == 0);

  // getsockopt returns doubled size. So, if we pass the same value to
  // setsockopt, it would double the buffer size.
  int newSize = static_cast<int>(size * factor / 2);
  len = sizeof(newSize);
  JASSERT(_real_setsockopt(fd,
                           SOL_SOCKET,
                           SO_SNDBUF,
                           (void *)&newSize,
                           len) == 0);
}

static KernelBufferDrainer *theDrainer = NULL;
KernelBufferDrainer&
KernelBufferDrainer::instance()
{
  if (theDrainer == NULL) {
    theDrainer = new KernelBufferDrainer();
  }
  return *theDrainer;
}

void
KernelBufferDrainer::onConnect(const jalib::JSocket &sock,
                               const struct sockaddr *remoteAddr,
                               socklen_t remoteLen)
{
  JWARNING(false) (sock.sockfd())
  .Text("we don't yet support checkpointing non-accepted connections..."
        " restore will likely fail.. closing connection");
  jalib::JSocket(sock).close();
}

void
KernelBufferDrainer::onData(jalib::JReaderInterface *sock)
{
  int fd = sock->socket().sockfd();
  // Detect and cache socket type
  JASSERT(_isSeqpacket.find(fd) != _isSeqpacket.end()) (fd);

  if (_isSeqpacket[fd]) {
    // Each onData corresponds to one full frame from JSeqpacketReader
    dmtcp::vector<char> frame;
    frame.resize(sock->bytesRead());
    memcpy(frame.data(), sock->buffer(), sock->bytesRead());
    _drainedFrames[fd].push_back(frame);
    sock->reset();
  } else {
    vector<char> &buffer = _drainedData[fd];
    buffer.resize(buffer.size() + sock->bytesRead());
    int startIdx = buffer.size() - sock->bytesRead();
    memcpy(&buffer[startIdx], sock->buffer(), sock->bytesRead());
    sock->reset();
  }
}

void
KernelBufferDrainer::onDisconnect(jalib::JReaderInterface *sock)
{
  int fd;

  errno = 0;
  fd = sock->socket().sockfd();

  // check if this was on purpose
  if (fd < 0) {
    return;
  }
  JTRACE("found disconnected socket... marking it dead")
    (fd) (_reverseLookup[fd]) (JASSERT_ERRNO);
  _disconnectedSockets[_reverseLookup[fd]] = _drainedData[fd];

  // _drainedData is used to refill socket buffers. Remove the disconnected
  // socket from this list. Disconnected sockets are refilled when they are
  // recreated by _makeDeadSocket().
  _drainedData.erase(fd);
}

void
KernelBufferDrainer::onTimeoutInterval()
{
  int count = 0;

  for (size_t i = 0; i < _dataSockets.size(); ++i) {
    if (_dataSockets[i]->bytesRead() > 0) {
      onData(_dataSockets[i]);
    }
    int fd = _dataSockets[i]->socket().sockfd();
    if (_isSeqpacket[fd]) {
      dmtcp::vector< dmtcp::vector<char> > &frames = _drainedFrames[fd];
      if (!frames.empty()) {
        dmtcp::vector<char> &last = frames.back();
        if ((size_t)last.size() == sizeof(theMagicDrainCookie) &&
            memcmp(last.data(), theMagicDrainCookie,
                   sizeof(theMagicDrainCookie)) == 0) {
          // Remove cookie frame and mark drained
          frames.pop_back();
          JTRACE("seqpacket drain complete") (fd) (frames.size())
            ((_dataSockets.size()));
          _dataSockets[i]->socket() = -1; // poison socket
          continue;
        }
      }
      ++count;
    } else {
      vector<char> &buffer = _drainedData[fd];
      if (buffer.size() >= sizeof(theMagicDrainCookie)
          && memcmp(&buffer[buffer.size() - sizeof(theMagicDrainCookie)],
                    theMagicDrainCookie,
                    sizeof(theMagicDrainCookie)) == 0) {
        buffer.resize(buffer.size() - sizeof(theMagicDrainCookie));
        JTRACE("buffer drain complete") (fd)
          (buffer.size()) ((_dataSockets.size()));
        _dataSockets[i]->socket() = -1; // poison socket
      } else {
        ++count;
      }
    }
  }

  if (count == 0) {
    _listenSockets.clear();
  } else {
    const static int WARN_INTERVAL_TICKS =
      (int)(DRAINER_WARNING_FREQ / DRAINER_CHECK_FREQ + 0.5);
    const static float WARN_INTERVAL_SEC =
      WARN_INTERVAL_TICKS * DRAINER_CHECK_FREQ;
    if (_timeoutCount++ > WARN_INTERVAL_TICKS) {
      _timeoutCount = 0;
      for (size_t i = 0; i < _dataSockets.size(); ++i) {
        vector<char> &buffer = _drainedData[_dataSockets[i]->socket().sockfd()];
        JWARNING(false) (_dataSockets[i]->socket().sockfd())
          (buffer.size()) (WARN_INTERVAL_SEC)
        .Text("Still draining socket... "
              "perhaps remote host is not running under DMTCP?");
#ifdef CERN_CMS
        JNOTE("\n*** Closing this socket (to database?).  Please use dmtcp \n"
              "***  plugins to gracefully handle such sockets, and re-run.\n"
              "***  Trying a workaround for now, and hoping it doesn't fail.\n"
             );
        _real_close(_dataSockets[i]->socket().sockfd());

        // it does it by creating a socket pair and closing one side
        int sp[2] = { -1, -1 };
        JASSERT(_real_socketpair(AF_UNIX, SOCK_STREAM, 0, sp) == 0)
          (JASSERT_ERRNO).Text("socketpair() failed");
        JASSERT(sp[0] >= 0 && sp[1] >= 0) (sp[0]) (sp[1])
        .Text("socketpair() failed");
        _real_close(sp[1]);
        JTRACE("created dead socket") (sp[0]);
        _real_dup2(sp[0], _dataSockets[i]->socket().sockfd());
#endif // ifdef CERN_CMS
      }
    }
  }
}

void
KernelBufferDrainer::beginDrainOf(int fd, const ConnectionIdentifier &id, int baseType)
{
  // JTRACE("will drain socket") (fd);
  _drainedData[fd]; // create buffer
  _drainedFrames[fd]; // create frames list (possibly unused)
  // this is the simple way:  jalib::JSocket(fd) << theMagicDrainCookie;
  // instead used delayed write in case kernel buffer is full:
  addWrite(new jalib::JChunkWriter(fd, theMagicDrainCookie,
                                   sizeof theMagicDrainCookie));

  // now setup a reader:
  if (_isSeqpacket[fd] = (baseType == SOCK_SEQPACKET)) {
    addDataSocket(new JSeqpacketReader(fd));
  } else {
    addDataSocket(new jalib::JChunkReader(fd, 512));
  }

  // insert it in reverse lookup
  _reverseLookup[fd] = id;
}

void
KernelBufferDrainer::refillAllSockets()
{
  JTRACE("refilling socket buffers") (_drainedData.size());

  // Refill stream sockets using a nonblocking duplex state machine.
  //
  // The previous implementation wrote every complete saved buffer before it
  // started reading any peer buffer.  When both endpoints had large saved
  // buffers, both sides could block in writeAll() before either side reached
  // the read phase.  Transfer headers, payloads, and echoes incrementally
  // across all stream sockets instead.
  struct StreamRefillState
  {
    int fd;

    ConnMsg outgoingMsg;
    size_t outgoingMsgOffset;

    vector<char> *outgoingData;
    size_t outgoingDataOffset;

    ConnMsg incomingMsg;
    size_t incomingMsgOffset;
    bool incomingMsgReady;

    vector<char> incomingData;
    size_t incomingDataOffset;

    size_t echoOffset;

    StreamRefillState(int socketFd, vector<char> *data)
      : fd(socketFd),
        outgoingMsg(ConnMsg::REFILL),
        outgoingMsgOffset(0),
        outgoingData(data),
        outgoingDataOffset(0),
        incomingMsg(),
        incomingMsgOffset(0),
        incomingMsgReady(false),
        incomingData(),
        incomingDataOffset(0),
        echoOffset(0)
    {
      JASSERT(data->size() <= 0x7fffffffUL)
        (socketFd) (data->size())
        .Text("refill buffer is too large for ConnMsg::extraBytes");

      outgoingMsg.extraBytes = static_cast<int>(data->size());
      incomingMsg.poison();
    }

    bool outgoingComplete() const
    {
      return outgoingMsgOffset == sizeof(ConnMsg) &&
             outgoingDataOffset == outgoingData->size();
    }

    bool incomingComplete() const
    {
      return incomingMsgReady &&
             incomingDataOffset == incomingData.size();
    }

    bool echoComplete() const
    {
      return incomingComplete() && echoOffset == incomingData.size();
    }

    bool done() const
    {
      return outgoingComplete() && incomingComplete() && echoComplete();
    }
  };

  map<int, vector<char> >::iterator i;
  vector<StreamRefillState> streamStates;

  for (i = _drainedData.begin(); i != _drainedData.end(); ++i) {
    int fd = i->first;
    if (_isSeqpacket[fd]) {
      continue;
    }

    // Preserve the original temporary send-buffer scaling.
    scaleSendBuffers(fd, 2);
    streamStates.push_back(StreamRefillState(fd, &i->second));
  }

  size_t unfinished = streamStates.size();

  while (unfinished > 0) {
    bool madeProgress = false;
    unfinished = 0;

    for (size_t index = 0; index < streamStates.size(); ++index) {
      StreamRefillState &state = streamStates[index];

      if (state.done()) {
        continue;
      }

      // Receive the peer's REFILL header.
      if (!state.incomingMsgReady) {
        char *destination =
          reinterpret_cast<char *>(&state.incomingMsg) +
          state.incomingMsgOffset;
        size_t remaining = sizeof(ConnMsg) - state.incomingMsgOffset;

        ssize_t count = ::recv(state.fd,
                               destination,
                               remaining,
                               MSG_DONTWAIT);

        if (count > 0) {
          state.incomingMsgOffset += static_cast<size_t>(count);
          madeProgress = true;

          if (state.incomingMsgOffset == sizeof(ConnMsg)) {
            state.incomingMsg.assertValid(ConnMsg::REFILL);
            JASSERT(state.incomingMsg.extraBytes >= 0)
              (state.fd) (state.incomingMsg.extraBytes)
              .Text("negative stream-refill payload size");

            state.incomingData.resize(
              static_cast<size_t>(state.incomingMsg.extraBytes));
            state.incomingMsgReady = true;
          }
        } else if (count == 0) {
          JASSERT(false)
            (state.fd)
            .Text("peer closed during stream-refill header receive");
        } else if (errno != EAGAIN &&
                   errno != EWOULDBLOCK &&
                   errno != EINTR) {
          JASSERT(false)
            (state.fd) (JASSERT_ERRNO)
            .Text("stream-refill header receive failed");
        }
      }

      // Receive the peer's saved payload.
      if (state.incomingMsgReady &&
          state.incomingDataOffset < state.incomingData.size()) {
        char *destination = &state.incomingData[state.incomingDataOffset];
        size_t remaining =
          state.incomingData.size() - state.incomingDataOffset;

        ssize_t count = ::recv(state.fd,
                               destination,
                               remaining,
                               MSG_DONTWAIT);

        if (count > 0) {
          state.incomingDataOffset += static_cast<size_t>(count);
          madeProgress = true;
        } else if (count == 0) {
          JASSERT(false)
            (state.fd)
            .Text("peer closed during stream-refill payload receive");
        } else if (errno != EAGAIN &&
                   errno != EWOULDBLOCK &&
                   errno != EINTR) {
          JASSERT(false)
            (state.fd) (JASSERT_ERRNO)
            .Text("stream-refill payload receive failed");
        }
      }

      // Send our REFILL header.
      if (state.outgoingMsgOffset < sizeof(ConnMsg)) {
        const char *source =
          reinterpret_cast<const char *>(&state.outgoingMsg) +
          state.outgoingMsgOffset;
        size_t remaining = sizeof(ConnMsg) - state.outgoingMsgOffset;

        ssize_t count = ::send(state.fd,
                               source,
                               remaining,
                               MSG_DONTWAIT | MSG_NOSIGNAL);

        if (count > 0) {
          state.outgoingMsgOffset += static_cast<size_t>(count);
          madeProgress = true;
        } else if (count < 0 &&
                   errno != EAGAIN &&
                   errno != EWOULDBLOCK &&
                   errno != EINTR) {
          JASSERT(false)
            (state.fd) (JASSERT_ERRNO)
            .Text("stream-refill header send failed");
        }
      }

      // Send our saved payload after our header.
      if (state.outgoingMsgOffset == sizeof(ConnMsg) &&
          state.outgoingDataOffset < state.outgoingData->size()) {
        const char *source =
          &(*state.outgoingData)[state.outgoingDataOffset];
        size_t remaining =
          state.outgoingData->size() - state.outgoingDataOffset;

        ssize_t count = ::send(state.fd,
                               source,
                               remaining,
                               MSG_DONTWAIT | MSG_NOSIGNAL);

        if (count > 0) {
          state.outgoingDataOffset += static_cast<size_t>(count);
          madeProgress = true;
        } else if (count < 0 &&
                   errno != EAGAIN &&
                   errno != EWOULDBLOCK &&
                   errno != EINTR) {
          JASSERT(false)
            (state.fd) (JASSERT_ERRNO)
            .Text("stream-refill payload send failed");
        }
      }

      // Echo the peer payload only after our complete REFILL frame has been
      // sent.  This preserves stream ordering: our header and payload must
      // precede the echoed peer data.
      if (state.outgoingComplete() &&
          state.incomingComplete() &&
          state.echoOffset < state.incomingData.size()) {
        const char *source = &state.incomingData[state.echoOffset];
        size_t remaining = state.incomingData.size() - state.echoOffset;

        ssize_t count = ::send(state.fd,
                               source,
                               remaining,
                               MSG_DONTWAIT | MSG_NOSIGNAL);

        if (count > 0) {
          state.echoOffset += static_cast<size_t>(count);
          madeProgress = true;
        } else if (count < 0 &&
                   errno != EAGAIN &&
                   errno != EWOULDBLOCK &&
                   errno != EINTR) {
          JASSERT(false)
            (state.fd) (JASSERT_ERRNO)
            .Text("stream-refill echo send failed");
        }
      }

      if (!state.done()) {
        ++unfinished;
      }
    }

    if (unfinished == 0) {
      break;
    }

    // If no socket transferred data during this pass, wait until at least one
    // unfinished socket becomes readable or writable, then retry all sockets.
    if (!madeProgress) {
      vector<struct pollfd> waitFds;

      for (size_t index = 0; index < streamStates.size(); ++index) {
        StreamRefillState &state = streamStates[index];
        if (state.done()) {
          continue;
        }

        struct pollfd descriptor;
        descriptor.fd = state.fd;
        descriptor.events = 0;
        descriptor.revents = 0;

        if (!state.incomingComplete()) {
          descriptor.events |= POLLIN;
        }

        if (!state.outgoingComplete() ||
            (state.incomingComplete() && !state.echoComplete())) {
          descriptor.events |= POLLOUT;
        }

        JASSERT(descriptor.events != 0)
          (state.fd)
          .Text("stream-refill state has no pollable operation");

        waitFds.push_back(descriptor);
      }

      JASSERT(!waitFds.empty())
        .Text("stream-refill has unfinished work but no sockets to poll");

      int pollResult;
      do {
        pollResult = ::poll(&waitFds[0],
                            static_cast<nfds_t>(waitFds.size()),
                            1000);
      } while (pollResult < 0 && errno == EINTR);

      JASSERT(pollResult >= 0)
        (JASSERT_ERRNO)
        .Text("poll failed during duplex stream refill");
    }
  }

  // All stream REFILL messages and echoes have completed.  The echoed data now
  // remains in each receive queue as the restored application data.
  for (size_t index = 0; index < streamStates.size(); ++index) {
    streamStates[index].outgoingData->clear();
    scaleSendBuffers(streamStates[index].fd, 0.5);
  }

  // Now handle seqpacket sockets: send frames and echo back peer frames
  map<int, dmtcp::vector< dmtcp::vector<char> > >::iterator f;
  for (f = _drainedFrames.begin(); f != _drainedFrames.end(); ++f) {
    int fd = f->first;
    if (!_isSeqpacket[fd]) {
      continue;
    }
    // Send our frames
    scaleSendBuffers(fd, 2);
    jalib::JSocket sock(fd);
    ConnMsg msgOut(ConnMsg::REFILL);
    msgOut.extraBytes = (int)f->second.size();
    sock << msgOut;
    for (size_t k = 0; k < f->second.size(); ++k) {
      uint32_t len32 = (uint32_t)f->second[k].size();
      sock.writeAll((const char *)&len32, sizeof(len32));
      if (len32 > 0) {
        sock.writeAll(f->second[k].data(), len32);
      }
    }
    f->second.clear();
  }

  // Read peer frames and echo back
  for (f = _drainedFrames.begin(); f != _drainedFrames.end(); ++f) {
    int fd = f->first;
    if (!_isSeqpacket[fd]) {
      continue;
    }
    jalib::JSocket sock(fd);
    ConnMsg msgIn;
    msgIn.poison();
    sock >> msgIn;
    msgIn.assertValid(ConnMsg::REFILL);
    int count = msgIn.extraBytes;
    for (int c = 0; c < count; ++c) {
      uint32_t len32 = 0;
      sock.readAll((char *)&len32, sizeof(len32));
      if (len32 > 0) {
        jalib::JBuffer tmp(len32);
        sock.readAll(tmp, len32);
        sock.writeAll((const char *)&len32, sizeof(len32));
        sock.writeAll(tmp, len32);
      } else {
        sock.writeAll((const char *)&len32, sizeof(len32));
      }
    }
    scaleSendBuffers(fd, 0.5);
  }

  JTRACE("buffers refilled");

  // Free up the object
  delete theDrainer;
  theDrainer = NULL;
}

const vector<char>&
KernelBufferDrainer::getDrainedData(ConnectionIdentifier id)
{
  JASSERT(_disconnectedSockets.find(id) != _disconnectedSockets.end()) (id);
  return _disconnectedSockets[id];
}
