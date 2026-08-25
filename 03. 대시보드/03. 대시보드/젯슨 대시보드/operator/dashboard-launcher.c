#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    const char *name = strrchr(argv[0], '/');
    name = name ? name + 1 : argv[0];

    const char *script = NULL;
    if (strstr(name, "START_DASHBOARD"))
        script = "/home/jetson/projects/zybo-security-demo/operator/start-dashboard.sh";
    else if (strstr(name, "STOP_DASHBOARD"))
        script = "/home/jetson/projects/zybo-security-demo/operator/stop-dashboard.sh";
    else if (strstr(name, "CHECK_STATUS"))
        script = "/home/jetson/projects/zybo-security-demo/operator/check-status.sh";
    else {
        fprintf(stderr, "Unknown dashboard launcher name: %s\n", name);
        return 2;
    }

    execl(script, script, (char *)NULL);
    fprintf(stderr, "Cannot launch %s: %s\n", script, strerror(errno));
    return 1;
}
