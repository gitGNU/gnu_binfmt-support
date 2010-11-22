/* run-detectors.c - run userspace format detectors
 *
 * Copyright (c) 2002, 2010 Colin Watson <cjwatson@debian.org>.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <dirent.h>
#include <assert.h>
#include <sys/types.h>

#include <pipeline.h>

#include "argp.h"
#include "gl_xlist.h"
#include "gl_array_list.h"
#include "xalloc.h"
#include "xstrndup.h"
#include "xvasprintf.h"

#include "error.h"
#include "format.h"
#include "paths.h"

char *program_name;

static size_t expand_hex (char **str)
{
    size_t len;
    char *new, *p, *s;

    /* The returned string is always no longer than the original. */
    len = strlen (*str);
    p = new = xmalloc (len + 1);
    s = *str;
    while (*s) {
	if (s <= *str + len - 4 && s[0] == '\\' && s[1] == 'x') {
	    char *end;
	    long hex = strtol (s + 2, &end, 16);
	    if (end == s + 4) {
		*p++ = (char) hex;
		s += 4;
		continue;
	    }
	}
	*p++ = *s++;
    }
    *p = 0;

    free (*str);
    *str = new;
    return p - new;
}

static void load_all_formats (gl_list_t *formats)
{
    DIR *dir;
    struct dirent *entry;

    dir = opendir (admindir);
    if (!dir)
	quit_err ("unable to open %s", admindir);
    *formats = gl_list_create_empty (GL_ARRAY_LIST, NULL, NULL, NULL, true);
    while ((entry = readdir (dir)) != NULL) {
	char *admindir_name;
	struct binfmt *binfmt;
	size_t mask_size;

	if (!strcmp (entry->d_name, ".") || !strcmp (entry->d_name, ".."))
	    continue;
	admindir_name = xasprintf ("%s/%s", admindir, entry->d_name);
	binfmt = binfmt_load (entry->d_name, admindir_name, 0);
	free (admindir_name);

	/* binfmt_load should always make these at least empty strings,
	 * never null pointers.
	 */
	assert (binfmt->type);
	assert (binfmt->magic);
	assert (binfmt->mask);
	assert (binfmt->offset);
	assert (binfmt->interpreter);
	assert (binfmt->detector);

	binfmt->magic_size = expand_hex (&binfmt->magic);
	mask_size = expand_hex (&binfmt->mask);
	if (mask_size && mask_size != binfmt->magic_size) {
	    /* A warning here would be inappropriate, as it would often be
	     * emitted for unrelated programs.
	     */
	    binfmt_free (binfmt);
	    continue;
	}
	if (!*binfmt->offset)
	    binfmt->offset = xstrdup ("0");
	gl_list_add_last (*formats, binfmt);
    }
    closedir (dir);
}

const char *argp_program_version = "binfmt-support " PACKAGE_VERSION;
const char *argp_program_bug_address = PACKAGE_BUGREPORT;

enum opts {
    OPT_ADMINDIR = 256
};

static struct argp_option options[] = {
    { "admindir",	OPT_ADMINDIR,	"DIRECTORY",	0,
	"administration directory (default: /var/lib/binfmts)" },
    { 0 }
};

static error_t parse_opt (int key, char *arg, struct argp_state *state)
{
    switch (key) {
	case OPT_ADMINDIR:
	    admindir = arg;
	    return 0;
    }

    return ARGP_ERR_UNKNOWN;
}

static struct argp argp = {
    options, parse_opt,
    "<target>",
    "\v"
    "Copyright (C) 2002, 2010 Colin Watson.\n"
    "This is free software; see the GNU General Public License version 3 or\n"
    "later for copying conditions."
};

int main (int argc, char **argv)
{
    gl_list_t formats, ok_formats;
    gl_list_iterator_t format_iter;
    const struct binfmt *binfmt;
    size_t toread;
    char *buf;
    FILE *target_file;
    const char *dot, *extension = NULL;
    int arg_index;
    char **real_argv;
    int i;

    program_name = xstrdup ("run-detectors");

    argp_err_exit_status = 2;
    if (argp_parse (&argp, argc, argv, ARGP_IN_ORDER, &arg_index, 0))
	exit (argp_err_exit_status);
    if (arg_index >= argc)
	quit ("argument required");

    load_all_formats (&formats);

    /* Find out how much of the file we need to read.  The kernel doesn't
     * currently let this be more than 128, so we shouldn't need to worry
     * about huge memory consumption.
     */
    toread = 0;
    format_iter = gl_list_iterator (formats);
    while (gl_list_iterator_next (&format_iter, (const void **) &binfmt,
				  NULL)) {
	if (!strcmp (binfmt->type, "magic")) {
	    size_t size;

	    size = atoi (binfmt->offset);
	    size += binfmt->magic ? strlen (binfmt->magic) : 0;
	    if (size > toread)
		toread = size;
	}
    }
    gl_list_iterator_free (&format_iter);

    buf = xzalloc (toread);
    target_file = fopen (argv[arg_index], "r");
    if (!target_file)
	quit_err ("unable to open %s", argv[arg_index]);
    if (fread (buf, 1, toread, target_file) == 0)
	/* Ignore errors; the buffer is zero-filled so attempts to match
	 * beyond the data read here will fail anyway.
	 */
	;
    fclose (target_file);

    /* Now the horrible bit.  Since there isn't a real way to plug userspace
     * detectors into the kernel (which is why this program exists in the
     * first place), we have to redo the kernel's work.  Luckily it's a
     * fairly simple job ... see linux/fs/binfmt_misc.c:check_file().
     *
     * There is a small race between the kernel performing this check and us
     * performing it.  I don't believe that this is a big deal; certainly
     * there can be no privilege elevation involved unless somebody
     * deliberately makes a set-id binary a binfmt handler, in which case
     * "don't do that, then".
     */
    dot = strrchr (argv[arg_index], '.');
    if (dot)
	extension = dot + 1;

    ok_formats = gl_list_create_empty (GL_ARRAY_LIST, NULL, NULL, NULL, true);
    format_iter = gl_list_iterator (formats);
    while (gl_list_iterator_next (&format_iter, (const void **) &binfmt,
				  NULL)) {
	if (!strcmp (binfmt->type, "magic")) {
	    char *segment;

	    segment = xstrndup (buf + atoi (binfmt->offset),
				binfmt->magic ? strlen (binfmt->magic) : 0);
	    if (*binfmt->mask)
		for (size_t i = 0; i < toread; ++i)
		    segment[i] &= binfmt->mask[i];
	    if (!memcmp (segment, binfmt->magic, binfmt->magic_size))
		gl_list_add_last (ok_formats, binfmt);
	} else {
	    if (extension && !strcmp (extension, binfmt->magic))
		gl_list_add_last (ok_formats, binfmt);
	}
    }
    gl_list_iterator_free (&format_iter);

    real_argv = xcalloc (argc - arg_index + 2, sizeof *real_argv);
    for (i = arg_index; i < argc; ++i)
	real_argv[i - arg_index + 1] = argv[i];
    real_argv[argc - arg_index + 1] = NULL;

    /* Everything in ok_formats is now a candidate.  Loop through twice,
     * once to try everything with a detector and once to try everything
     * without.  As soon as one succeeds, exec() it.
     */
    format_iter = gl_list_iterator (ok_formats);
    while (gl_list_iterator_next (&format_iter, (const void **) &binfmt,
				  NULL)) {
	if (*binfmt->detector) {
	    pipeline *detector;

	    detector = pipeline_new_command_args (binfmt->detector,
						  argv[arg_index], NULL);
	    if (pipeline_run (detector) == 0) {
		real_argv[0] = (char *) binfmt->interpreter;
		fflush (NULL);
		execvp (binfmt->interpreter, real_argv);
		warning_err ("unable to exec %s", binfmt->interpreter);
	    }
	}
    }
    gl_list_iterator_free (&format_iter);

    format_iter = gl_list_iterator (ok_formats);
    while (gl_list_iterator_next (&format_iter, (const void **) &binfmt,
				  NULL)) {
	if (!*binfmt->detector) {
	    real_argv[0] = (char *) binfmt->interpreter;
	    fflush (NULL);
	    execvp (binfmt->interpreter, real_argv);
	    warning_err ("unable to exec %s", binfmt->interpreter);
	}
    }
    gl_list_iterator_free (&format_iter);

    quit ("unable to find an interpreter for %s", argv[arg_index]);
}
