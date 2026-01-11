/*
 * Poyo - Secure Getty/Login for Galactica Linux
 * 
 * A minimal, secure login program that:
 * - Shows a login prompt on any TTY (serial, virtual console, etc.)
 * - Validates credentials against /etc/shadow
 * - Uses secure password handling
 * - Implements rate limiting and security best practices
 * - Starts the user's shell after successful authentication
 * - Can be spawned for multiple TTYs (tty1, tty2, ttyS0, etc.)
 *
 * Usage: poyo [tty_device]
 *   poyo              - Use current stdin/stdout
 *   poyo /dev/tty1    - Run on virtual console 1
 *   poyo /dev/ttyS0   - Run on serial console
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <grp.h>
#include <shadow.h>
#include <crypt.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <signal.h>
#include <syslog.h>
#include <utmp.h>
#include <paths.h>

#define MAX_USERNAME 256
#define MAX_PASSWORD 512
#define MAX_ATTEMPTS 3
#define DELAY_AFTER_FAIL 3
#define VERSION "1.1.0"

static char g_tty_path[256] = "";
static char g_tty_name[64] = "console";

/* Security: Clear sensitive data from memory */
static void secure_zero(void *ptr, size_t len) {
    volatile unsigned char *p = ptr;
    while (len--) {
        *p++ = 0;
    }
}

/* Security: Disable core dumps to prevent password leaks */
static void disable_core_dumps(void) {
    struct rlimit rlim;
    rlim.rlim_cur = 0;
    rlim.rlim_max = 0;
    setrlimit(RLIMIT_CORE, &rlim);
}

/* Security: Set up signal handlers */
static void setup_signals(void) {
    signal(SIGINT, SIG_IGN);   /* Ignore Ctrl+C */
    signal(SIGQUIT, SIG_IGN);  /* Ignore Ctrl+\ */
    signal(SIGTSTP, SIG_IGN);  /* Ignore Ctrl+Z */
    signal(SIGHUP, SIG_IGN);   /* Ignore hangup */
}

/* Open and setup TTY device */
static int setup_tty(const char *tty_device) {
    int fd;
    
    if (!tty_device || tty_device[0] == '\0') {
        /* Use current stdin/stdout */
        strncpy(g_tty_name, ttyname(STDIN_FILENO) ? ttyname(STDIN_FILENO) : "console", sizeof(g_tty_name) - 1);
        return 0;
    }
    
    strncpy(g_tty_path, tty_device, sizeof(g_tty_path) - 1);
    
    /* Extract tty name from path */
    const char *name = strrchr(tty_device, '/');
    if (name) {
        name++;
    } else {
        name = tty_device;
    }
    strncpy(g_tty_name, name, sizeof(g_tty_name) - 1);
    
    /* Close existing stdio */
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    
    /* Open TTY for input */
    fd = open(tty_device, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        /* Try to log error somewhere */
        int logfd = open("/dev/kmsg", O_WRONLY);
        if (logfd >= 0) {
            dprintf(logfd, "poyo: cannot open %s: %s\n", tty_device, strerror(errno));
            close(logfd);
        }
        return -1;
    }
    
    /* Make this our controlling terminal */
    setsid();
    ioctl(fd, TIOCSCTTY, 1);
    
    /* Setup stdio */
    dup2(fd, STDIN_FILENO);
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    
    if (fd > STDERR_FILENO) {
        close(fd);
    }
    
    /* Configure terminal */
    struct termios tty;
    if (tcgetattr(STDIN_FILENO, &tty) == 0) {
        /* Enable canonical mode, echo, signals */
        tty.c_lflag |= (ICANON | ECHO | ISIG);
        tty.c_iflag |= (ICRNL);
        tty.c_oflag |= (OPOST | ONLCR);
        tcsetattr(STDIN_FILENO, TCSANOW, &tty);
    }
    
    return 0;
}

/* Display the banner */
static void display_banner(void) {
    printf("\033[2J\033[H");  /* Clear screen and move cursor to top */
    printf("\033[38;5;213m");  /* Pink color */
    printf("\n");
    printf("  ________       .__                 __  .__               \n");
    printf(" /  _____/_____  |  | _____    _____/  |_|__| ____ _____   \n");
    printf("/   \\  ___\\__  \\ |  | \\__  \\ _/ ___\\   __\\  |/ ___\\\\__  \\  \n");
    printf("\\    \\_\\  \\/ __ \\|  |__/ __ \\\\  \\___|  | |  \\  \\___ / __ \\_\n");
    printf(" \\______  (____  /____(____  /\\___  >__| |__|\\___  >____  /\n");
    printf("        \\/     \\/          \\/     \\/             \\/     \\/ \n");
    printf("\033[0m");  /* Reset color */
    printf("\n");
    printf("            Galactica Linux v0.1.0\n");
    printf("              Poyo Login v%s\n", VERSION);
    printf("              Console: %s\n", g_tty_name);
    printf("\n");
}

/* Security: Read password without echoing to terminal */
static int read_password(char *password, size_t max_len) {
    struct termios old_term, new_term;
    int c;
    size_t len = 0;
    
    /* Get current terminal settings */
    if (tcgetattr(STDIN_FILENO, &old_term) != 0) {
        /* Terminal not available, try basic read */
        if (fgets(password, max_len, stdin) != NULL) {
            password[strcspn(password, "\r\n")] = '\0';
            return 0;
        }
        return -1;
    }
    
    /* Disable echo */
    new_term = old_term;
    new_term.c_lflag &= ~(ECHO | ECHOE | ECHOK | ECHONL);
    
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &new_term) != 0) {
        return -1;
    }
    
    /* Read password character by character */
    while (len < max_len - 1) {
        c = getchar();
        
        if (c == EOF || c == '\n' || c == '\r') {
            break;
        }
        
        /* Handle backspace */
        if (c == 127 || c == 8) {
            if (len > 0) {
                len--;
                password[len] = '\0';
            }
            continue;
        }
        
        /* Security: Filter control characters */
        if (c < 32 || c > 126) {
            continue;
        }
        
        password[len++] = (char)c;
    }
    
    password[len] = '\0';
    
    /* Restore terminal settings */
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &old_term);
    
    printf("\n");
    return 0;
}

/* Security: Validate username - only alphanumeric, underscore, dash */
static int is_valid_username(const char *username) {
    size_t len;
    size_t i;
    
    if (!username || username[0] == '\0') {
        return 0;
    }
    
    len = strlen(username);
    
    /* Security: Limit username length */
    if (len > 32) {
        return 0;
    }
    
    /* First character must be letter or underscore */
    if (!((username[0] >= 'a' && username[0] <= 'z') ||
          (username[0] >= 'A' && username[0] <= 'Z') ||
          username[0] == '_')) {
        return 0;
    }
    
    /* Rest: alphanumeric, underscore, dash */
    for (i = 1; i < len; i++) {
        if (!((username[i] >= 'a' && username[i] <= 'z') ||
              (username[i] >= 'A' && username[i] <= 'Z') ||
              (username[i] >= '0' && username[i] <= '9') ||
              username[i] == '_' || username[i] == '-')) {
            return 0;
        }
    }
    
    return 1;
}

/* Security: Authenticate user against /etc/shadow */
static int authenticate_user(const char *username, const char *password) {
    struct spwd *shadow_entry;
    char *encrypted;
    int result = 0;
    const char *hash;
    
    /* Security: Must run as root to read /etc/shadow */
    if (geteuid() != 0) {
        syslog(LOG_ERR, "Poyo must run as root");
        return 0;
    }
    
    /* Get shadow entry for user */
    shadow_entry = getspnam(username);
    if (!shadow_entry) {
        /* Security: Log failed lookup */
        syslog(LOG_WARNING, "User not found: %s", username);
        /* Security: Still do the delay to prevent timing attacks */
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    hash = shadow_entry->sp_pwdp;
    
    /* Check if account is locked */
    /* Account is locked if password starts with ! or * 
     * BUT we need to handle the case where the hash itself starts with $
     * A locked account looks like: !$6$... or just ! or *
     * An unlocked account looks like: $6$... 
     */
    if (hash[0] == '*') {
        /* Completely disabled account */
        syslog(LOG_WARNING, "Account disabled: %s", username);
        printf("Account is disabled.\n");
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    if (hash[0] == '!' && hash[1] == '!') {
        /* Password never set (common in some systems) */
        syslog(LOG_WARNING, "Password never set for: %s", username);
        printf("Password not set. Contact administrator.\n");
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Skip leading ! for locked accounts - we'll still try to auth
     * This allows "locked" accounts that just have ! prepended to still work
     * if you know the password (useful for recovery) 
     * ACTUALLY - let's be strict about this for security */
    if (hash[0] == '!') {
        syslog(LOG_WARNING, "Account locked: %s", username);
        printf("Account is locked.\n");
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Check if password is empty (allow login without password) */
    if (hash[0] == '\0') {
        syslog(LOG_INFO, "Empty password login for: %s", username);
        return 1;
    }
    
    /* Verify password using crypt() */
    encrypted = crypt(password, hash);
    if (!encrypted) {
        syslog(LOG_ERR, "crypt() failed for user: %s", username);
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Compare hashes */
    if (strcmp(encrypted, hash) == 0) {
        result = 1;
        syslog(LOG_INFO, "Successful login: %s on %s", username, g_tty_name);
    } else {
        syslog(LOG_WARNING, "Failed login attempt for: %s on %s", username, g_tty_name);
        sleep(DELAY_AFTER_FAIL);
    }
    
    return result;
}

/* Set up environment for user session */
static int setup_environment(struct passwd *pwd) {
    char path_buf[1024];
    
    /* Clear all environment variables for security */
    if (clearenv() != 0) {
        return -1;
    }
    
    /* Set essential environment variables */
    setenv("HOME", pwd->pw_dir, 1);
    setenv("USER", pwd->pw_name, 1);
    setenv("LOGNAME", pwd->pw_name, 1);
    setenv("SHELL", pwd->pw_shell, 1);
    
    /* Set secure PATH */
    if (pwd->pw_uid == 0) {
        snprintf(path_buf, sizeof(path_buf),
                "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    } else {
        snprintf(path_buf, sizeof(path_buf),
                "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin");
    }
    setenv("PATH", path_buf, 1);
    
    /* Set terminal type based on tty */
    if (strstr(g_tty_name, "ttyS") || strstr(g_tty_name, "ttyUSB")) {
        setenv("TERM", "vt100", 1);  /* Serial terminal */
    } else {
        setenv("TERM", "linux", 1);   /* Virtual console */
    }
    
    /* Set TTY */
    if (g_tty_path[0]) {
        setenv("TTY", g_tty_path, 1);
    }
    
    /* Set prompt */
    setenv("PS1", "[\\u@\\h \\W]\\$ ", 1);
    
    /* Set DISPLAY if on a virtual console (for X) */
    if (strncmp(g_tty_name, "tty", 3) == 0 && g_tty_name[3] >= '1' && g_tty_name[3] <= '9') {
        setenv("DISPLAY", ":0", 1);
    }
    
    return 0;
}

/* Update utmp and wtmp for session tracking */
static void update_utmp(const char *username) {
    struct utmp ut;
    
    memset(&ut, 0, sizeof(ut));
    
    ut.ut_type = USER_PROCESS;
    ut.ut_pid = getpid();
    
    strncpy(ut.ut_user, username, sizeof(ut.ut_user) - 1);
    strncpy(ut.ut_line, g_tty_name, sizeof(ut.ut_line) - 1);
    
    ut.ut_tv.tv_sec = time(NULL);
    ut.ut_tv.tv_usec = 0;
    
    setutent();
    pututline(&ut);
    endutent();
    
    updwtmp(_PATH_WTMP, &ut);
    
    syslog(LOG_INFO, "Session started for %s on %s", username, g_tty_name);
}

/* Start user shell */
static void start_shell(struct passwd *pwd) {
    char *shell;
    char *shell_name;
    
    /* Change to user's home directory */
    if (chdir(pwd->pw_dir) != 0) {
        fprintf(stderr, "Warning: Could not change to home directory %s\n", pwd->pw_dir);
        if (chdir("/") != 0) {
            fprintf(stderr, "Error: Could not change to /\n");
            exit(EXIT_FAILURE);
        }
    }
    
    /* Security: Drop privileges to user */
    if (initgroups(pwd->pw_name, pwd->pw_gid) != 0 ||
        setgid(pwd->pw_gid) != 0 ||
        setuid(pwd->pw_uid) != 0) {
        fprintf(stderr, "Error: Failed to drop privileges\n");
        syslog(LOG_ERR, "Failed to drop privileges for user: %s", pwd->pw_name);
        exit(EXIT_FAILURE);
    }
    
    /* Verify privilege drop */
    if (getuid() != pwd->pw_uid || geteuid() != pwd->pw_uid) {
        fprintf(stderr, "Error: Failed to verify privilege drop\n");
        exit(EXIT_FAILURE);
    }
    
    /* Display message of the day */
    if (access("/etc/motd", R_OK) == 0) {
        FILE *motd = fopen("/etc/motd", "r");
        if (motd) {
            char line[256];
            while (fgets(line, sizeof(line), motd)) {
                printf("%s", line);
            }
            fclose(motd);
        }
    }
    
    /* Determine shell to use */
    shell = pwd->pw_shell;
    if (!shell || shell[0] == '\0') {
        shell = "/bin/sh";
    }
    
    /* Get shell name for argv[0] */
    shell_name = strrchr(shell, '/');
    if (shell_name) {
        shell_name++;
    } else {
        shell_name = shell;
    }
    
    syslog(LOG_INFO, "Starting shell %s for user: %s", shell, pwd->pw_name);
    
    /* Execute shell with login shell convention */
    char login_shell[256];
    snprintf(login_shell, sizeof(login_shell), "-%s", shell_name);
    
    execl(shell, login_shell, NULL);
    
    /* If execl fails */
    fprintf(stderr, "Error: Failed to execute shell: %s\n", shell);
    syslog(LOG_ERR, "Failed to execute shell %s for user: %s", shell, pwd->pw_name);
    exit(EXIT_FAILURE);
}

/* Print usage */
static void print_usage(const char *prog) {
    printf("Usage: %s [OPTIONS] [tty_device]\n", prog);
    printf("\n");
    printf("Galactica Linux Login\n");
    printf("\n");
    printf("Options:\n");
    printf("  -h, --help     Show this help\n");
    printf("  -v, --version  Show version\n");
    printf("\n");
    printf("Examples:\n");
    printf("  %s                 Use current terminal\n", prog);
    printf("  %s /dev/tty1       Run on virtual console 1\n", prog);
    printf("  %s /dev/ttyS0      Run on serial console\n", prog);
    printf("\n");
}

/* Main login loop */
int main(int argc, char *argv[]) {
    char username[MAX_USERNAME];
    char password[MAX_PASSWORD];
    char hostname[64];
    struct passwd *pwd;
    int attempts = 0;
    const char *tty_device = NULL;
    
    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return EXIT_SUCCESS;
        } else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--version") == 0) {
            printf("Poyo %s\n", VERSION);
            return EXIT_SUCCESS;
        } else if (argv[i][0] == '/') {
            tty_device = argv[i];
        }
    }
    
    /* Security: Disable core dumps */
    disable_core_dumps();
    
    /* Security: Set up signal handlers */
    setup_signals();
    
    /* Open syslog */
    openlog("poyo", LOG_PID | LOG_CONS, LOG_AUTH);
    
    /* Security: Verify we're running as root */
    if (geteuid() != 0) {
        fprintf(stderr, "Error: Poyo must be run as root\n");
        syslog(LOG_ERR, "Poyo started without root privileges");
        closelog();
        return EXIT_FAILURE;
    }
    
    /* Setup TTY if specified */
    if (tty_device) {
        if (setup_tty(tty_device) != 0) {
            syslog(LOG_ERR, "Failed to setup TTY: %s", tty_device);
            closelog();
            return EXIT_FAILURE;
        }
        syslog(LOG_INFO, "Poyo started on %s", tty_device);
    } else {
        /* Get current tty name */
        const char *current_tty = ttyname(STDIN_FILENO);
        if (current_tty) {
            const char *name = strrchr(current_tty, '/');
            strncpy(g_tty_name, name ? name + 1 : current_tty, sizeof(g_tty_name) - 1);
        }
    }
    
    /* Get hostname for prompt */
    if (gethostname(hostname, sizeof(hostname)) != 0) {
        strncpy(hostname, "galactica", sizeof(hostname) - 1);
        hostname[sizeof(hostname) - 1] = '\0';
    }
    
    /* Main login loop */
    while (attempts < MAX_ATTEMPTS) {
        display_banner();
        
        printf("%s login: ", hostname);
        fflush(stdout);
        
        if (fgets(username, sizeof(username), stdin) == NULL) {
            if (feof(stdin)) {
                printf("\n");
                closelog();
                return EXIT_SUCCESS;
            }
            continue;
        }
        
        username[strcspn(username, "\r\n")] = '\0';
        
        if (username[0] == '\0') {
            continue;
        }
        
        if (!is_valid_username(username)) {
            printf("Invalid username\n");
            syslog(LOG_WARNING, "Invalid username format: %s", username);
            sleep(DELAY_AFTER_FAIL);
            attempts++;
            continue;
        }
        
        printf("Password: ");
        fflush(stdout);
        
        if (read_password(password, sizeof(password)) != 0) {
            fprintf(stderr, "Error reading password\n");
            attempts++;
            continue;
        }
        
        if (authenticate_user(username, password)) {
            secure_zero(password, sizeof(password));
            
            pwd = getpwnam(username);
            if (!pwd) {
                fprintf(stderr, "Error: Could not get user information\n");
                syslog(LOG_ERR, "getpwnam failed for: %s", username);
                closelog();
                return EXIT_FAILURE;
            }
            
            if (setup_environment(pwd) != 0) {
                fprintf(stderr, "Error: Could not set up environment\n");
                closelog();
                return EXIT_FAILURE;
            }
            
            update_utmp(username);
            closelog();
            
            start_shell(pwd);
            return EXIT_FAILURE;
        }
        
        secure_zero(password, sizeof(password));
        
        printf("Login incorrect\n\n");
        attempts++;
        
        sleep(DELAY_AFTER_FAIL * attempts);
    }
    
    printf("\nToo many failed login attempts.\n");
    syslog(LOG_WARNING, "Too many failed attempts on %s", g_tty_name);
    closelog();
    
    /* Sleep and restart for getty behavior */
    sleep(5);
    
    return EXIT_FAILURE;
}
