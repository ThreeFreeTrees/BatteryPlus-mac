/* batteryplus-lowpower.c — the app's privileged piece, as a setuid-root tool rather than a daemon.
 *
 * Why not the launchd daemon this replaces (kept for the record in spikes/007-low-power-daemon):
 * every loaded launchd job appears in System Settings → Login Items → Background App Activity, and
 * the only supported way to give that row a proper icon is registering the job through SMAppService,
 * which the system refuses under an ad-hoc signature (measured: EPERM, from /Applications included).
 * A setuid tool is not a registered background item, so the app stays the only row.
 *
 * It does ONE thing, and there is no argument that reaches a shell: fixed program, fixed flags, fixed
 * environment. It also refuses to act for anyone but the user at the console — the same rule the
 * daemon enforced on its socket.
 *
 * Exit codes: 0 or pmset's own status; 2 no console user; 3 not the console user; 4 bad arguments;
 *             5 exec failed.
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#define PMSET   "/usr/bin/pmset"
#define CONSOLE "/dev/console"

int main(int argc, char *argv[]) {
    /* getuid() is the *real* uid — the person who ran us, not root. /dev/console is owned by whoever
     * is at the console (root when nobody is logged in). */
    struct stat console;
    if (stat(CONSOLE, &console) != 0 || console.st_uid == 0) return 2;
    if (getuid() != console.st_uid) {
        fprintf(stderr, "batteryplus-lowpower: only the user at the console may change Low Power Mode\n");
        return 3;
    }

    if (argc != 3) {
        fprintf(stderr, "usage: batteryplus-lowpower <battery|ac> <0|1>\n");
        return 4;
    }
    const char *scope = argv[1];
    const char *value = argv[2];
    if (strcmp(scope, "battery") != 0 && strcmp(scope, "ac") != 0) return 4;
    if (strcmp(value, "0") != 0 && strcmp(value, "1") != 0) return 4;

    char *const pmsetArgs[] = { (char *)PMSET, (char *)(scope[0] == 'b' ? "-b" : "-c"),
                                (char *)"lowpowermode", (char *)value, NULL };
    char *const emptyEnv[] = { NULL };   /* no PATH, nothing inherited to smuggle anything through */
    execve(PMSET, pmsetArgs, emptyEnv);

    perror("batteryplus-lowpower: exec");
    return 5;
}
