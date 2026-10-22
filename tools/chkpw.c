/* chkpw USER: read a candidate password on stdin, compare with USER's shadow hash. */
#include <shadow.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	char pw[256] = "";
	if (argc < 2 || fgets(pw, sizeof(pw), stdin) == NULL) { fprintf(stderr, "usage: chkpw user < password\n"); return 2; }
	pw[strcspn(pw, "\n")] = '\0';
	struct spwd *sp = getspnam(argv[1]);
	if (sp == NULL) { puts("no shadow entry"); return 2; }
	const char *h = crypt(pw, sp->sp_pwdp);
	int ok = h != NULL && strcmp(h, sp->sp_pwdp) == 0;
	const char *e = crypt("", sp->sp_pwdp);
	printf("candidate: %s; empty password: %s\n", ok ? "MATCH" : "no match", e && !strcmp(e, sp->sp_pwdp) ? "MATCH" : "no match");
	return ok ? 0 : 1;
}
