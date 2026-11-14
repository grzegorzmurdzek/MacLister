#!/usr/bin/env python3
"""Small FTP / FTPS server for MacLister's tests. Standard library only, listens on 127.0.0.1.

  mock_ftp_server.py --port 2121 --root DIR [--user test --password secret]
                     [--tls explicit|implicit --cert cert.pem --key key.pem] [--verbose]

Supports: USER PASS SYST FEAT OPTS PWD CWD CDUP TYPE PASV LIST RETR STOR SIZE DELE MKD RMD RNFR RNTO NOOP QUIT
and, with --tls, AUTH TLS PBSZ PROT. EPSV is refused so clients fall back to PASV.
"""
import argparse, os, socket, socketserver, ssl, stat, sys, time, threading

args = None
ssl_ctx = None


def log(*a):
    if args.verbose:
        print(*a, file=sys.stderr, flush=True)


class Handler(socketserver.StreamRequestHandler):
    def setup(self):
        self.request.settimeout(30)
        if args.tls == "implicit":
            self.request = ssl_ctx.wrap_socket(self.request, server_side=True)
        super().setup()
        self.cwd = "/"
        self.authed = False
        self.user = None
        self.rnfr = None
        self.pasv = None
        self.prot_p = False

    # --- helpers
    def send(self, line):
        log("->", line)
        self.wfile.write((line + "\r\n").encode("utf-8"))
        self.wfile.flush()

    def real(self, arg):
        path = arg if arg.startswith("/") else self.cwd.rstrip("/") + "/" + arg
        parts = []
        for p in path.split("/"):
            if p in ("", "."):
                continue
            if p == "..":
                if parts:
                    parts.pop()
                continue
            parts.append(p)
        virtual = "/" + "/".join(parts)
        return virtual, os.path.join(args.root, *parts)

    def open_data(self):
        if self.pasv is None:
            raise RuntimeError("no PASV")
        self.pasv.settimeout(10)
        conn, _ = self.pasv.accept()
        self.pasv.close()
        self.pasv = None
        if self.prot_p:
            conn = ssl_ctx.wrap_socket(conn, server_side=True)
        conn.settimeout(30)
        return conn

    @staticmethod
    def close_data(conn):
        try:
            if isinstance(conn, ssl.SSLSocket):
                try:
                    conn = conn.unwrap()
                except Exception:
                    pass
            conn.close()
        except Exception:
            pass

    @staticmethod
    def list_line(name, st, link=None):
        mode = stat.filemode(st.st_mode)
        when = time.localtime(st.st_mtime)
        if time.time() - st.st_mtime > 180 * 86400:
            stamp = time.strftime("%b %d  %Y", when)
        else:
            stamp = time.strftime("%b %d %H:%M", when)
        shown = name + (" -> " + link if link else "")
        return "%s %3d %-8s %-8s %12d %s %s" % (mode, st.st_nlink, "ftp", "ftp", st.st_size, stamp, shown)

    # --- main loop
    def handle(self):
        self.send("220 MacLister mock FTP ready")
        while True:
            try:
                raw = self.rfile.readline()
            except Exception:
                return
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            log("<-", line if not line.upper().startswith("PASS") else "PASS ****")
            cmd, _, arg = line.partition(" ")
            cmd = cmd.upper()
            try:
                if not self.dispatch(cmd, arg):
                    return
            except (ssl.SSLError, ConnectionError, socket.timeout):
                return
            except Exception as e:  # keep serving
                log("error:", repr(e))
                try:
                    self.send("451 Local error: %s" % e)
                except Exception:
                    return

    def dispatch(self, cmd, arg):
        if cmd == "USER":
            self.user = arg
            self.send("331 Password required")
        elif cmd == "PASS":
            if self.user == args.user and arg == args.password:
                self.authed = True
                self.send("230 Logged in")
            else:
                self.send("530 Login incorrect")
        elif cmd == "QUIT":
            self.send("221 Bye")
            return False
        elif cmd == "AUTH" and args.tls == "explicit" and arg.upper() in ("TLS", "TLS-C"):
            self.send("234 Proceed with TLS")
            self.request = ssl_ctx.wrap_socket(self.request, server_side=True)
            self.rfile = self.request.makefile("rb")
            self.wfile = self.request.makefile("wb")
        elif cmd == "PBSZ":
            self.send("200 PBSZ=0")
        elif cmd == "PROT":
            self.prot_p = arg.upper() == "P"
            self.send("200 Protection set")
        elif cmd == "SYST":
            self.send("215 UNIX Type: L8")
        elif cmd == "FEAT":
            feats = ["SIZE", "UTF8"] + (["AUTH TLS", "PBSZ", "PROT"] if args.tls == "explicit" else [])
            self.send("211-Features:")
            for f in feats:
                self.send(" " + f)
            self.send("211 End")
        elif cmd == "OPTS" or cmd == "NOOP" or cmd == "TYPE" or cmd == "MODE" or cmd == "STRU":
            self.send("200 OK")
        elif not self.authed:
            self.send("530 Please log in")
        elif cmd == "PWD":
            self.send('257 "%s" is the current directory' % self.cwd)
        elif cmd == "CWD":
            virtual, real = self.real(arg)
            if os.path.isdir(real):
                self.cwd = virtual
                self.send("250 OK")
            else:
                self.send("550 No such directory")
        elif cmd == "CDUP":
            self.cwd, _ = self.real("..")
            self.send("250 OK")
        elif cmd == "EPSV":
            self.send("502 EPSV not implemented")
        elif cmd == "PASV":
            if self.pasv:
                self.pasv.close()
            self.pasv = socket.socket()
            self.pasv.bind(("127.0.0.1", 0))
            self.pasv.listen(1)
            port = self.pasv.getsockname()[1]
            self.send("227 Entering Passive Mode (127,0,0,1,%d,%d)" % (port >> 8, port & 255))
        elif cmd == "LIST":
            target = arg
            if target.startswith("-"):
                target = ""
            virtual, real = self.real(target or ".")
            if not os.path.exists(real):
                self.send("550 No such file or directory")
                return True
            self.send("150 Here comes the listing")
            conn = self.open_data()
            lines = []
            names = sorted(os.listdir(real)) if os.path.isdir(real) else [os.path.basename(real)]
            base = real if os.path.isdir(real) else os.path.dirname(real)
            for name in names:
                full = os.path.join(base, name)
                st = os.lstat(full)
                link = os.readlink(full) if stat.S_ISLNK(st.st_mode) else None
                lines.append(self.list_line(name, st, link))
            conn.sendall(("\r\n".join(lines) + ("\r\n" if lines else "")).encode("utf-8"))
            self.close_data(conn)
            self.send("226 Transfer complete")
        elif cmd == "SIZE":
            _, real = self.real(arg)
            if os.path.isfile(real):
                self.send("213 %d" % os.path.getsize(real))
            else:
                self.send("550 Not a file")
        elif cmd == "RETR":
            _, real = self.real(arg)
            if not os.path.isfile(real):
                self.send("550 No such file")
                return True
            self.send("150 Opening data connection")
            conn = self.open_data()
            with open(real, "rb") as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    conn.sendall(chunk)
            self.close_data(conn)
            self.send("226 Transfer complete")
        elif cmd == "STOR":
            _, real = self.real(arg)
            if not os.path.isdir(os.path.dirname(real)):
                self.send("550 Directory does not exist")
                return True
            self.send("150 Ok to send data")
            conn = self.open_data()
            with open(real, "wb") as f:
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    f.write(chunk)
            self.close_data(conn)
            self.send("226 Transfer complete")
        elif cmd == "DELE":
            _, real = self.real(arg)
            if os.path.isfile(real) or os.path.islink(real):
                os.remove(real)
                self.send("250 Deleted")
            else:
                self.send("550 No such file")
        elif cmd == "MKD":
            virtual, real = self.real(arg)
            try:
                os.mkdir(real)
                self.send('257 "%s" created' % virtual)
            except OSError as e:
                self.send("550 %s" % e.strerror)
        elif cmd == "RMD":
            _, real = self.real(arg)
            try:
                os.rmdir(real)
                self.send("250 Removed")
            except OSError as e:
                self.send("550 %s" % e.strerror)
        elif cmd == "RNFR":
            _, real = self.real(arg)
            if os.path.lexists(real):
                self.rnfr = real
                self.send("350 Ready for RNTO")
            else:
                self.send("550 No such file")
        elif cmd == "RNTO":
            _, real = self.real(arg)
            if self.rnfr:
                try:
                    os.rename(self.rnfr, real)
                    self.send("250 Renamed")
                except OSError as e:
                    self.send("550 %s" % e.strerror)
                self.rnfr = None
            else:
                self.send("503 RNFR first")
        else:
            self.send("502 Command not implemented")
        return True


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global args, ssl_ctx
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--user", default="test")
    p.add_argument("--password", default="secret")
    p.add_argument("--tls", choices=["none", "explicit", "implicit"], default="none")
    p.add_argument("--cert")
    p.add_argument("--key")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()
    args.root = os.path.realpath(args.root)
    if args.tls != "none":
        ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_ctx.load_cert_chain(args.cert, args.key)
    with Server(("127.0.0.1", args.port), Handler) as server:
        print("ready", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
