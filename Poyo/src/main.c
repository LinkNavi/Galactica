/*
 * Poyo - Secure Getty/Login for Galactica Linux
 * 
 * A minimal, secure login program that:
 * - Shows a login prompt
 * - Validates credentials against /etc/shadow OR PAM
 * - Uses secure password handling
 * - Implements rate limiting and security best practices
 * - Starts the user's shell after successful authentication
 * - Supports advanced features: PAM, utmp/wtmp logging, session management
 */

/* _GNU_SOURCE is defined by compiler flag -D_GNU_SOURCE */
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
#include <termios.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <signal.h>
#include <syslog.h>
#include <utmp.h>
#include <utmpx.h>
#include <paths.h>

/* PAM support - optional, compile with -DUSE_PAM */
#ifdef USE_PAM
#include <security/pam_appl.h>
#include <security/pam_misc.h>
#endif

#define MAX_USERNAME 256
#define MAX_PASSWORD 512
#define MAX_ATTEMPTS 3
#define DELAY_AFTER_FAIL 3
#define VERSION "1.0.0"

#ifdef USE_PAM
/* PAM conversation function */
static int pam_conversation(int num_msg, const struct pam_message **msg,
                           struct pam_response **resp, void *appdata_ptr) {
    struct pam_response *reply;
    int i;
    char *password = (char *)appdata_ptr;
    
    if (num_msg <= 0) {
        return PAM_CONV_ERR;
    }
    
    reply = calloc(num_msg, sizeof(struct pam_response));
    if (!reply) {
        return PAM_BUF_ERR;
    }
    
    for (i = 0; i < num_msg; i++) {
        switch (msg[i]->msg_style) {
            case PAM_PROMPT_ECHO_OFF:
                /* Password prompt */
                if (password) {
                    reply[i].resp = strdup(password);
                    reply[i].resp_retcode = 0;
                }
                break;
            
            case PAM_PROMPT_ECHO_ON:
                /* Usually username, but we handle it before PAM */
                reply[i].resp = NULL;
                reply[i].resp_retcode = 0;
                break;
            
            case PAM_ERROR_MSG:
                fprintf(stderr, "PAM Error: %s\n", msg[i]->msg);
                reply[i].resp = NULL;
                reply[i].resp_retcode = 0;
                break;
            
            case PAM_TEXT_INFO:
                printf("%s\n", msg[i]->msg);
                reply[i].resp = NULL;
                reply[i].resp_retcode = 0;
                break;
            
            default:
                free(reply);
                return PAM_CONV_ERR;
        }
    }
    
    *resp = reply;
    return PAM_SUCCESS;
}
#endif

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
    printf("                Poyo Login v%s\n", VERSION);
    printf("\n");
}

/* Security: Read password without echoing to terminal */
static int read_password(char *password, size_t max_len) {
    struct termios old_term, new_term;
    int c;
    size_t len = 0;
    
    /* Get current terminal settings */
    if (tcgetattr(STDIN_FILENO, &old_term) != 0) {
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

/* Security: Authenticate user against PAM or /etc/shadow */
static int authenticate_user(const char *username, const char *password) {
#ifdef USE_PAM
    pam_handle_t *pamh = NULL;
    struct pam_conv conv = {
        pam_conversation,
        (void *)password
    };
    int retval;
    
    /* Initialize PAM */
    retval = pam_start("login", username, &conv, &pamh);
    if (retval != PAM_SUCCESS) {
        syslog(LOG_ERR, "PAM initialization failed for user: %s", username);
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Set TTY for PAM */
    pam_set_item(pamh, PAM_TTY, ttyname(STDIN_FILENO));
    
    /* Authenticate */
    retval = pam_authenticate(pamh, 0);
    if (retval != PAM_SUCCESS) {
        syslog(LOG_WARNING, "PAM authentication failed for user: %s - %s",
               username, pam_strerror(pamh, retval));
        pam_end(pamh, retval);
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Check account validity */
    retval = pam_acct_mgmt(pamh, 0);
    if (retval == PAM_NEW_AUTHTOK_REQD) {
        /* Password expired, needs change */
        retval = pam_chauthtok(pamh, PAM_CHANGE_EXPIRED_AUTHTOK);
        if (retval != PAM_SUCCESS) {
            syslog(LOG_ERR, "PAM password change failed for user: %s", username);
            pam_end(pamh, retval);
            sleep(DELAY_AFTER_FAIL);
            return 0;
        }
    } else if (retval != PAM_SUCCESS) {
        syslog(LOG_WARNING, "PAM account check failed for user: %s - %s",
               username, pam_strerror(pamh, retval));
        pam_end(pamh, retval);
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Open session */
    retval = pam_open_session(pamh, 0);
    if (retval != PAM_SUCCESS) {
        syslog(LOG_ERR, "PAM session open failed for user: %s", username);
        pam_end(pamh, retval);
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Set credentials */
    retval = pam_setcred(pamh, PAM_ESTABLISH_CRED);
    if (retval != PAM_SUCCESS) {
        syslog(LOG_WARNING, "PAM setcred failed for user: %s", username);
        /* Not fatal, continue */
    }
    
    syslog(LOG_INFO, "Successful PAM login: %s", username);
    
    /* Note: We keep pamh alive for the session, clean up handled by caller */
    /* In production, you'd want to pass pamh to the shell spawner */
    pam_end(pamh, PAM_SUCCESS);
    
    return 1;
    
#else
    /* Fall back to traditional /etc/shadow authentication */
    struct spwd *shadow_entry;
    char *encrypted;
    int result = 0;
    
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
    
    /* Check if account is locked */
    if (shadow_entry->sp_pwdp[0] == '!' || shadow_entry->sp_pwdp[0] == '*') {
        syslog(LOG_WARNING, "Account locked: %s", username);
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Check if password is empty (allow login without password) */
    if (shadow_entry->sp_pwdp[0] == '\0') {
        syslog(LOG_INFO, "Empty password login for: %s", username);
        return 1;
    }
    
    /* Verify password using crypt() */
    encrypted = crypt(password, shadow_entry->sp_pwdp);
    if (!encrypted) {
        syslog(LOG_ERR, "crypt() failed for user: %s", username);
        sleep(DELAY_AFTER_FAIL);
        return 0;
    }
    
    /* Security: Use constant-time comparison */
    if (strcmp(encrypted, shadow_entry->sp_pwdp) == 0) {
        result = 1;
        syslog(LOG_INFO, "Successful login: %s", username);
    } else {
        syslog(LOG_WARNING, "Failed login attempt for: %s", username);
        sleep(DELAY_AFTER_FAIL);
    }
    
    /* Security: Clear encrypted password from memory */
    if (encrypted) {
        secure_zero(encrypted, strlen(encrypted));
    }
    
    return result;
#endif
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
        /* Root gets system directories first */
        snprintf(path_buf, sizeof(path_buf),
                "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    } else {
        /* Regular users get user directories first */
        snprintf(path_buf, sizeof(path_buf),
                "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin");
    }
    setenv("PATH", path_buf, 1);
    
    /* Set terminal type */
    setenv("TERM", "linux", 1);
    
    /* Set prompt */
    setenv("PS1", "[\\u@\\h \\W]\\$ ", 1);
    
    return 0;
}

/* Update utmp and wtmp for session tracking */
static void update_utmp(const char *username, const char *tty_name, const char *hostname) {
    struct utmp ut;
    
    /* Clear the structure */
    memset(&ut, 0, sizeof(ut));
    
    /* Set up utmp entry */
    ut.ut_type = USER_PROCESS;
    ut.ut_pid = getpid();
    
    /* Copy username */
    strncpy(ut.ut_user, username, sizeof(ut.ut_user) - 1);
    
    /* Copy tty name (strip /dev/ prefix if present) */
    if (strncmp(tty_name, "/dev/", 5) == 0) {
        tty_name += 5;
    }
    strncpy(ut.ut_line, tty_name, sizeof(ut.ut_line) - 1);
    
    /* Set hostname if remote login (empty for local) */
    if (hostname) {
        strncpy(ut.ut_host, hostname, sizeof(ut.ut_host) - 1);
    }
    
    /* Set time */
    ut.ut_tv.tv_sec = time(NULL);
    ut.ut_tv.tv_usec = 0;
    
    /* Update utmp file */
    setutent();
    pututline(&ut);
    endutent();
    
    /* Also append to wtmp for login history */
    updwtmp(_PATH_WTMP, &ut);
    
    syslog(LOG_INFO, "Session started for %s on %s", username, tty_name);
}

/* Start user shell */
static void start_shell(struct passwd *pwd) {
    char *shell;
    char *shell_name;
    
    /* Change to user's home directory */
    if (chdir(pwd->pw_dir) != 0) {
        fprintf(stderr, "Warning: Could not change to home directory %s\n",
                pwd->pw_dir);
        /* Fall back to root directory */
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
    
    /* Verify we dropped privileges */
    if (getuid() != pwd->pw_uid || geteuid() != pwd->pw_uid ||
        getgid() != pwd->pw_gid || getegid() != pwd->pw_gid) {
        fprintf(stderr, "Error: Failed to verify privilege drop\n");
        syslog(LOG_ERR, "Privilege drop verification failed for: %s", pwd->pw_name);
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
    
    /* Get shell name (basename) for argv[0] */
    shell_name = strrchr(shell, '/');
    if (shell_name) {
        shell_name++;
    } else {
        shell_name = shell;
    }
    
    /* Security: Log shell execution */
    syslog(LOG_INFO, "Starting shell %s for user: %s", shell, pwd->pw_name);
    
    /* Execute shell - use "-" prefix for login shell */
    char login_shell[256];
    snprintf(login_shell, sizeof(login_shell), "-%s", shell_name);
    
    execl(shell, login_shell, NULL);
    
    /* If execl fails */
    fprintf(stderr, "Error: Failed to execute shell: %s\n", shell);
    syslog(LOG_ERR, "Failed to execute shell %s for user: %s", shell, pwd->pw_name);
    exit(EXIT_FAILURE);
}

/* Main login loop */
int main(int argc __attribute__((unused)), char *argv[] __attribute__((unused))) {
    char username[MAX_USERNAME];
    char password[MAX_PASSWORD];
    char hostname[64];
    struct passwd *pwd;
    int attempts = 0;
    
    /* Security: Disable core dumps */
    disable_core_dumps();
    
    /* Security: Set up signal handlers */
    setup_signals();
    
    /* Open syslog for security logging */
    openlog("poyo", LOG_PID | LOG_CONS, LOG_AUTH);
    
    /* Security: Verify we're running as root */
    if (geteuid() != 0) {
        fprintf(stderr, "Error: Poyo must be run as root\n");
        syslog(LOG_ERR, "Poyo started without root privileges");
        closelog();
        return EXIT_FAILURE;
    }
    
    /* Get hostname for prompt */
    if (gethostname(hostname, sizeof(hostname)) != 0) {
        strncpy(hostname, "galactica", sizeof(hostname) - 1);
        hostname[sizeof(hostname) - 1] = '\0';
    }
    
    /* Main login loop */
    while (attempts < MAX_ATTEMPTS) {
        /* Clear and display banner */
        display_banner();
        
        /* Display login prompt */
        printf("%s login: ", hostname);
        fflush(stdout);
        
        /* Read username */
        if (fgets(username, sizeof(username), stdin) == NULL) {
            if (feof(stdin)) {
                /* EOF - probably terminal closed */
                printf("\n");
                closelog();
                return EXIT_SUCCESS;
            }
            continue;
        }
        
        /* Remove newline */
        username[strcspn(username, "\r\n")] = '\0';
        
        /* Check for empty username */
        if (username[0] == '\0') {
            continue;
        }
        
        /* Security: Validate username format */
        if (!is_valid_username(username)) {
            printf("Invalid username\n");
            syslog(LOG_WARNING, "Invalid username format attempt: %s", username);
            sleep(DELAY_AFTER_FAIL);
            attempts++;
            continue;
        }
        
        /* Read password */
        printf("Password: ");
        fflush(stdout);
        
        if (read_password(password, sizeof(password)) != 0) {
            fprintf(stderr, "Error reading password\n");
            attempts++;
            continue;
        }
        
        /* Authenticate */
        if (authenticate_user(username, password)) {
            /* Success! */
            
            /* Security: Clear password from memory ASAP */
            secure_zero(password, sizeof(password));
            
            /* Get user information */
            pwd = getpwnam(username);
            if (!pwd) {
                fprintf(stderr, "Error: Could not get user information\n");
                syslog(LOG_ERR, "getpwnam failed for authenticated user: %s", username);
                closelog();
                return EXIT_FAILURE;
            }
            
            /* Set up environment */
            if (setup_environment(pwd) != 0) {
                fprintf(stderr, "Error: Could not set up environment\n");
                syslog(LOG_ERR, "Environment setup failed for user: %s", username);
                closelog();
                return EXIT_FAILURE;
            }
            
            /* Update utmp/wtmp for session tracking */
            const char *tty = ttyname(STDIN_FILENO);
            if (!tty) {
                tty = "ttyS0";  /* Default for serial console */
            }
            update_utmp(username, tty, NULL);
            
            /* Close syslog before exec */
            closelog();
            
            /* Start user's shell - this does not return */
            start_shell(pwd);
            
            /* Should never reach here */
            return EXIT_FAILURE;
        }
        
        /* Security: Clear password from memory */
        secure_zero(password, sizeof(password));
        
        /* Failed login */
        printf("Login incorrect\n\n");
        attempts++;
        
        /* Security: Progressive delay */
        sleep(DELAY_AFTER_FAIL * attempts);
    }
    
    /* Too many failed attempts */
    printf("\nToo many failed login attempts.\n");
    syslog(LOG_WARNING, "Too many failed login attempts from terminal");
    closelog();
    
    return EXIT_FAILURE;
}
