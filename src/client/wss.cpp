// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "client/wss.h"
#include "core/log.h"
#include <c55/os.h> // get_timeofday_us()
#include "interface/tcpsocket.h"
#include <mbedtls/ssl.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/base64.h>
#include "interface/address.h"
#include <mbedtls/error.h>
#include <mbedtls/net_sockets.h>
#ifdef _WIN32
	#include "ports/windows_sockets.h"
#else
	#include <sys/socket.h>
#endif

#define MODULE "__wss"

namespace client {

bool parse_secure_address(const ss_ &address, ss_ *host, ss_ *port)
{
	interface::Url u;
	if(!interface::parse_url(address, &u) ||
			(u.scheme != "https" && u.scheme != "wss"))
		return false;
	*host = u.host;
	*port = u.port;
	return true;
}

static ss_ tls_error(int r)
{
	char buf[200];
	mbedtls_strerror(r, buf, sizeof buf);
	return buf;
}

struct CWss: public Wss
{
	interface::TCPSocket *m_socket;
	mbedtls_ssl_context m_ssl;
	mbedtls_ssl_config m_conf;
	mbedtls_x509_crt m_ca;
	mbedtls_ctr_drbg_context m_drbg;
	mbedtls_entropy_context m_entropy;
	// The handshake and the upgrade wait for the server; after them a read
	// takes only what is there
	bool m_blocking = true;
	// What has come of the server's frames and is not a whole one yet
	ss_ m_in;
	bool m_unread = false;
	// The second's reading, for the log
	size_t m_bytes = 0, m_records = 0, m_inside = 0;
	int64_t m_said_us = 0;

	CWss(interface::TCPSocket *socket): m_socket(socket)
	{
		mbedtls_ssl_init(&m_ssl);
		mbedtls_ssl_config_init(&m_conf);
		mbedtls_x509_crt_init(&m_ca);
		mbedtls_ctr_drbg_init(&m_drbg);
		mbedtls_entropy_init(&m_entropy);
	}
	~CWss()
	{
		mbedtls_ssl_free(&m_ssl);
		mbedtls_ssl_config_free(&m_conf);
		mbedtls_x509_crt_free(&m_ca);
		mbedtls_ctr_drbg_free(&m_drbg);
		mbedtls_entropy_free(&m_entropy);
	}

	static int bio_send(void *ctx, const unsigned char *buf, size_t len)
	{
		CWss *w = (CWss*)ctx;
		if(!w->m_socket->send_fd(ss_((const char*)buf, len)))
			return MBEDTLS_ERR_NET_SEND_FAILED;
		return (int)len;
	}
	static int bio_recv(void *ctx, unsigned char *buf, size_t len)
	{
		CWss *w = (CWss*)ctx;
		if(!w->m_socket->wait_data(w->m_blocking ? 15000000 : 0))
			return w->m_blocking ? MBEDTLS_ERR_SSL_TIMEOUT :
					MBEDTLS_ERR_SSL_WANT_READ;
		const int r = recv(w->m_socket->fd(), (char*)buf, (int)len, 0);
		if(r < 0)
			return MBEDTLS_ERR_NET_RECV_FAILED;
		return r; // 0: the server closed the connection
	}

	ss_ start(const ss_ &host, const ss_ &port, const ss_ &ca_path)
	{
		int r = mbedtls_ctr_drbg_seed(&m_drbg, mbedtls_entropy_func,
				&m_entropy, nullptr, 0);
		if(r == 0){
			r = mbedtls_x509_crt_parse_file(&m_ca, ca_path.c_str());
			if(r < 0)
				return "the certificate roots ("+ca_path+"): "+tls_error(r);
		}
		if(r >= 0)
			r = mbedtls_ssl_config_defaults(&m_conf, MBEDTLS_SSL_IS_CLIENT,
					MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
		if(r == 0){
			mbedtls_ssl_conf_authmode(&m_conf, MBEDTLS_SSL_VERIFY_REQUIRED);
			mbedtls_ssl_conf_ca_chain(&m_conf, &m_ca, nullptr);
			mbedtls_ssl_conf_rng(&m_conf, mbedtls_ctr_drbg_random, &m_drbg);
			r = mbedtls_ssl_setup(&m_ssl, &m_conf);
		}
		if(r == 0)
			r = mbedtls_ssl_set_hostname(&m_ssl, host.c_str());
		if(r != 0)
			return "TLS: "+tls_error(r);
		mbedtls_ssl_set_bio(&m_ssl, this, bio_send, bio_recv, nullptr);
		while((r = mbedtls_ssl_handshake(&m_ssl)) != 0){
			if(r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE)
				return "TLS with "+host+": "+tls_error(r);
		}

		// The upgrade, as a browser asks for it
		unsigned char nonce[16];
		mbedtls_ctr_drbg_random(&m_drbg, nonce, sizeof nonce);
		unsigned char key[32];
		size_t key_len = 0;
		mbedtls_base64_encode(key, sizeof key, &key_len, nonce, sizeof nonce);
		if(!write_all("GET / HTTP/1.1\r\n"
				"Host: "+host+(port == "443" ? "" : ":"+port)+"\r\n"
				"Upgrade: websocket\r\n"
				"Connection: Upgrade\r\n"
				"Sec-WebSocket-Key: "+ss_((char*)key, key_len)+"\r\n"
				"Sec-WebSocket-Version: 13\r\n"
				"Sec-WebSocket-Protocol: binary\r\n"
				"\r\n"))
			return "TLS: the upgrade did not go";
		// simplified: the status line only; Sec-WebSocket-Accept is not
		// checked, as TLS has already said who answers
		ss_ head;
		while(head.find("\r\n\r\n") == ss_::npos){
			char buf[4096];
			r = mbedtls_ssl_read(&m_ssl, (unsigned char*)buf, sizeof buf);
			if(r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
				continue;
			if(r <= 0)
				return "the server closed the connection at the upgrade";
			head.append(buf, r);
			if(head.size() > 16384)
				return "no answer to the upgrade";
		}
		const size_t end = head.find("\r\n\r\n");
		if(head.compare(0, 12, "HTTP/1.1 101") != 0)
			return "not a WebSocket there: "+head.substr(0, head.find('\r'));
		m_in = head.substr(end + 4);
		m_unread = !m_in.empty();
		m_blocking = false;
		return "";
	}

	bool write_all(const ss_ &data)
	{
		size_t at = 0;
		while(at < data.size()){
			const int r = mbedtls_ssl_write(&m_ssl,
					(const unsigned char*)data.data() + at, data.size() - at);
			if(r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
				continue;
			if(r < 0)
				return false;
			at += r;
		}
		return true;
	}

	// A client's frame: always masked
	bool send_frame(int opcode, const ss_ &payload)
	{
		ss_ f;
		f += (char)(0x80 | opcode);
		const size_t n = payload.size();
		if(n < 126){
			f += (char)(0x80 | n);
		} else if(n < 65536){
			f += (char)(0x80 | 126);
			f += (char)(n >> 8);
			f += (char)n;
		} else {
			f += (char)(0x80 | 127);
			for(int i = 7; i >= 0; i--)
				f += (char)((uint64_t)n >> (i * 8));
		}
		unsigned char mask[4];
		mbedtls_ctr_drbg_random(&m_drbg, mask, 4);
		f.append((char*)mask, 4);
		const size_t at = f.size();
		f += payload;
		for(size_t i = 0; i < n; i++)
			f[at + i] ^= mask[i & 3];
		return write_all(f);
	}

	bool send(const ss_ &data)
	{
		return send_frame(2, data);
	}

	// **Every record there is, up to a megabyte** ([JOIN_DRAIN], user
	// 2026-10-11: a 21 MB start came at 330 KB/s): a read of one record,
	// 16 KB at most, nearly always ends inside a frame of a world's
	// packets, and a read that gave nothing ended the update's reading --
	// a record an update
	int read(ss_ &out, ss_ *why)
	{
		char buf[100000];
		size_t took = 0;
		while(took < 1000000){
			const int r = mbedtls_ssl_read(&m_ssl, (unsigned char*)buf,
					sizeof buf);
			// What came with the upgrade's answer is framed too
			m_unread = false;
			if(r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
				break;
			if(r == 0 || r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY){
				*why = "the server closed the connection";
				return -1;
			}
			if(r < 0){
				*why = "TLS: "+tls_error(r);
				return -1;
			}
			m_in.append(buf, r);
			took += r;
			m_records++;
		}
		const int n = deframe(out, why);
		// What came, once a second while it comes
		m_bytes += took;
		if(n == 0 && took > 0)
			m_inside++;
		const int64_t now = get_timeofday_us();
		if(m_bytes > 0 && now - m_said_us >= 1000000){
			log_v(MODULE, "TLS: %zu bytes in %zu records, %zu reads ended "
					"inside a frame", m_bytes, m_records, m_inside);
			m_said_us = now;
			m_bytes = m_records = m_inside = 0;
		}
		return n;
	}

	// The whole frames of m_in: a binary one's payload onto `out`
	int deframe(ss_ &out, ss_ *why)
	{
		const size_t before = out.size();
		size_t at = 0;
		for(;;){
			const ss_ &b = m_in;
			if(b.size() - at < 2)
				break;
			const int opcode = (unsigned char)b[at] & 0x0f;
			uint64_t len = (unsigned char)b[at + 1] & 0x7f;
			size_t h = 2;
			if(len == 126){
				if(b.size() - at < 4)
					break;
				len = ((uint64_t)(unsigned char)b[at + 2] << 8) |
						(unsigned char)b[at + 3];
				h = 4;
			} else if(len == 127){
				if(b.size() - at < 10)
					break;
				len = 0;
				for(int i = 0; i < 8; i++)
					len = (len << 8) | (unsigned char)b[at + 2 + i];
				h = 10;
			}
			if(b.size() - at - h < len)
				break;
			const ss_ payload = b.substr(at + h, len);
			at += h + len;
			if(opcode == 0 || opcode == 2){
				out += payload;
			} else if(opcode == 8){
				*why = "the server closed the connection";
				m_in.clear();
				return -1;
			} else if(opcode == 9){
				send_frame(10, payload);
			}
		}
		m_in.erase(0, at);
		return (int)(out.size() - before);
	}

	bool pending()
	{
		return m_unread || mbedtls_ssl_get_bytes_avail(&m_ssl) > 0;
	}
};

Wss* create_wss(interface::TCPSocket *socket)
{
	return new CWss(socket);
}

}
// vim: set noet ts=4 sw=4:
