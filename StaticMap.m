/*
 * Copyright (c) 2001 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * "Portions Copyright (c) 2001 Apple Computer, Inc.  All Rights
 * Reserved.  This file contains Original Code and/or Modifications of
 * Original Code as defined in and that are subject to the Apple Public
 * Source License Version 1.0 (the 'License').  You may not use this file
 * except in compliance with the License.  Please obtain a copy of the
 * License at http://www.apple.com/publicsource and read it before using
 * this file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT.  Please see the
 * License for the specific language governing rights and limitations
 * under the License."
 * 
 * @APPLE_LICENSE_HEADER_END@
 */
#import "StaticMap.h"
#import "Controller.h"
#import "AMString.h"
#import "AMVnode.h"
#import "automount.h"
#import "log.h"
#import <fstab.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <sys/stat.h>

@implementation StaticMap

- (void)setupLink:(Vnode *)v
{
	String *x;
	char *s;
	int len;

	if (v == nil) return;

	if ([[v server] isLocalHost])
	{
		[v setLink:[v source]];
		[v setMode:00755 | NFSMODE_LNK];
		[v setMounted:YES];
		[v setFakeMount:YES];
		return;
	}

	len = [mountPoint length] + [[v relativepath] length] + 1;
	s = malloc(len);
	sprintf(s, "%s%s", [mountPoint value], [[v relativepath] value]);

	x = [String uniqueString:s];
	free(s);
	[v setLink:x];
	[x release];
}

- (void)newMount:(String *)src dir:(String *)dst opts:(Array *)opts vfsType:(String *)type
{
	String *servername, *serversrc, *link;
	Vnode *v;
	Server *server;
	int status;
	struct stat sb;
	BOOL targetDirPotential;

	serversrc = [src postfix:':'];
	if (serversrc == nil) return;

	servername = [src prefix:':'];
	if (servername == nil)
	{
		[serversrc release];
		return;
	}

	server = [controller serverWithName:servername];
	if (server == nil)
	{
		[servername release];
		return;
	}

	if ([server isLocalHost])
	{
		[serversrc release];
		serversrc = [String uniqueString:"/"];
	}

	if (![self acceptOptions:opts])
	{
		sys_msg(debug, LOG_DEBUG, "Rejected options for %s on %s (StaticMap)",
			[src value], [dst value]);
		[servername release];
		[serversrc release];
		return;
	}

	/* It's important to try to blindly create the symlink first; peeking at the target of a static link
	   may trigger the /Network automounter, for instance, to populate its top-level directory looking
	   for the target directory name:
	 */
	link = [String concatStrings:[root path] :dst];
	targetDirPotential = YES;			/* Hope springs eternal (or twice, in any case) */

Try_link:
	status = symlink([link value], [dst value]);
	if (status != 0)
	{
		sys_msg(debug, LOG_ERR, "Error symlinking %s to %s: %s", [dst value], [link value], strerror(errno));
		if (targetDirPotential) {
			targetDirPotential = NO;		/* This will be our one and only shot at successfully retrying! */
			
			sys_msg(debug, LOG_ERR, "Attempting to unlink %s...", [dst value]);
			status = lstat([dst value], &sb);
			if (status == 0)
			{
				if (sb.st_mode & S_IFDIR) status = rmdir([dst value]);
				else status = unlink([dst value]);
				
				if (status == 0) goto Try_link;

				sys_msg(debug, LOG_ERR, "Cannot unlink %s: %s", [dst value], strerror(errno));
				[link release];
				[servername release];
				[serversrc release];
				return;
			}
		}
		
		sys_msg(debug, LOG_ERR, "Cannot symlink %s to %s: %s", [dst value], [link value], strerror(errno));
		[servername release];
		[serversrc release];
		[link release];
		return;
	}
	[link release];

	v = [self createVnodePath:dst from:root];
	if ([v type] == NFLNK)
	{
		/* mount already exists - do not override! */
		[servername release];
		[serversrc release];
		return;
	}

	[v setType:NFLNK];
	[v setServer:server];
	[v setSource:serversrc];
	[v setVfsType:type];
	[v setupOptions:opts];
	[v addMntArg:MNT_DONTBROWSE];
	[servername release];
	[serversrc release];
	[self setupLink:v];
}

- (void)loadMounts
{
	struct fstab *f;
	String *spec, *file, *type, *opts, *vfstype;
	String *netopt;
	Array *options;
	BOOL hasnet;

	netopt = [String uniqueString:"net"];

	setfsent();
	while (NULL != (f = getfsent()))
	{
		opts = [String uniqueString:f->fs_mntops];
		options = [opts explode:','];
		hasnet = [options containsObject:netopt];
		if (hasnet)
		{
			[opts release];
			[options release];
			continue;
		}

		spec = [String uniqueString:f->fs_spec];
		file = [String uniqueString:f->fs_file];
		type = [String uniqueString:f->fs_type];
		vfstype = [String uniqueString:f->fs_vfstype];

		if (type != nil) [options addObject:type];

		[self newMount:spec dir:file opts:options vfsType:vfstype];

		[spec release];
		[file release];
		[type release];
		[opts release];
		[options release];
		[vfstype release];
	}
	endfsent();
}

- (void)reInit
{
	[self removeLinksRecursively: root];
	[super reInit];
}

/*
 *	Before exiting, remove any symlinks we created at init time.
 */
- (void)cleanup
{
	[self removeLinksRecursively: root];
}


/*
 * As part of shutting down or reinitializing, remove any ordinary symlinks
 * that were created.  The path to the symlink is the Vnode's path minus the
 * leading part that is the path of the root node.
 *
 * For example, if the command link options were:
 *	-static /automount/static
 * and there is a static mount on /Network/Applications, then
 * /Network/Applications is a symlink to /automount/static/Network/Applications
 * and the root Vnode's path is /automount/static and the automount Vnode's
 * path is /automount/static/Network/Applications.  We need to remove the
 * /automount/static from the beginning and end up with /Network/Applications.
 */
- (void)removeLinksRecursively:(Vnode*)v
{
	int status, i, len;
	char *path;
	Array *kids;
	
	if ([v type] == NFLNK)
	{
		path = [[v path] value] + [[root path] length];
		sys_msg(debug, LOG_DEBUG, "unlinking %s", path);
		status = unlink(path);
		if (status != 0)
		{
			sys_msg(debug, LOG_ERR, "removeLinks cannot unlink %s: %s", path, strerror(errno));
		}
	}

	kids = [v children];
	len = 0;
	if (kids != nil)
		len = [kids count];
	for (i=0; i<len; ++i)
	{
		[self removeLinksRecursively: [kids objectAtIndex: i]];
	}
}


@end
