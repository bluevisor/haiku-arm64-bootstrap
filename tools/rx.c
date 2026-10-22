/* rx HOST PORT OUTFILE [MODE]: connect to HOST:PORT and save everything received. */
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: %s host port outfile [octal-mode]\n", argv[0]);
		return 2;
	}
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(atoi(argv[2])) };
	if (inet_pton(AF_INET, argv[1], &sa.sin_addr) != 1) { perror("inet_pton"); return 1; }
	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0 || connect(s, (struct sockaddr *)&sa, sizeof(sa)) < 0) { perror("connect"); return 1; }
	int fd = open(argv[3], O_WRONLY | O_CREAT | O_TRUNC, argc > 4 ? strtol(argv[4], NULL, 8) : 0644);
	if (fd < 0) { perror(argv[3]); return 1; }
	char buf[65536];
	ssize_t n;
	long long total = 0;
	while ((n = read(s, buf, sizeof(buf))) > 0) {
		if (write(fd, buf, n) != n) { perror("write"); return 1; }
		total += n;
	}
	if (n < 0) { perror("read"); return 1; }
	if (argc > 4)
		fchmod(fd, strtol(argv[4], NULL, 8));
	close(fd);
	printf("%lld bytes -> %s\n", total, argv[3]);
	return 0;
}
