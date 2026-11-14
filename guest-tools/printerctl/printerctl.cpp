/*
 * printerctl: add, remove and select Haiku printers without the Printers
 * preferences' dialogs (for scripts and ssh sessions).
 *   printerctl add <name> <driver> <transport> [<transport address>]
 *   printerctl remove <name>
 *   printerctl default <name>
 *   printerctl list
 */
#include <stdio.h>
#include <string.h>

#include <Directory.h>
#include <Entry.h>
#include <FindDirectory.h>
#include <Messenger.h>
#include <Node.h>
#include <NodeInfo.h>
#include <OS.h>
#include <OS.h>
#include <Path.h>
#include <Roster.h>
#include <Roster.h>
#include <String.h>

#include <pr_server.h>


static int
usage()
{
	fprintf(stderr, "usage: printerctl add <name> <driver> <transport> "
		"[<transport address>]\n"
		"       printerctl remove <name>\n"
		"       printerctl default <name>\n"
		"       printerctl list\n");
	return 2;
}


static void
write_string(BNode& node, const char* name, const char* value)
{
	node.WriteAttr(name, B_STRING_TYPE, 0, value, strlen(value) + 1);
}


int
main(int argc, char** argv)
{
	if (argc < 2)
		return usage();

	BPath printers;
	if (find_directory(B_USER_PRINTERS_DIRECTORY, &printers, true) != B_OK) {
		fprintf(stderr, "no printers directory\n");
		return 1;
	}

	if (strcmp(argv[1], "list") == 0) {
		BDirectory dir(printers.Path());
		BEntry entry;
		while (dir.GetNextEntry(&entry) == B_OK) {
			BNode node(&entry);
			BString driver, transport, address;
			node.ReadAttrString(PSRV_PRINTER_ATTR_DRV_NAME, &driver);
			node.ReadAttrString(PSRV_PRINTER_ATTR_TRANSPORT, &transport);
			node.ReadAttrString(PSRV_PRINTER_ATTR_TRANSPORT_ADDR, &address);
			printf("%s\t%s\t%s\t%s\n", entry.Name(), driver.String(),
				transport.String(), address.String());
		}
		return 0;
	}

	if (argc < 3)
		return usage();
	const char* name = argv[2];

	if (strcmp(argv[1], "add") == 0) {
		if (argc < 5)
			return usage();
		// Build the folder beside the printers folder and move it in once
		// complete, so print_server sees a finished printer.
		BPath temporary(printers);
		temporary.GetParent(&temporary);
		BString tempName("printer-");
		tempName << name;
		temporary.Append(tempName);
		BDirectory parent;
		BDirectory folder;
		BPath tempParent;
		temporary.GetParent(&tempParent);
		parent.SetTo(tempParent.Path());
		status_t status = parent.CreateDirectory(temporary.Leaf(), &folder);
		if (status != B_OK) {
			fprintf(stderr, "cannot create %s: %s\n", temporary.Path(),
				strerror(status));
			return 1;
		}
		BNodeInfo(&folder).SetType(PSRV_PRINTER_FILETYPE);
		write_string(folder, PSRV_PRINTER_ATTR_PRT_NAME, name);
		write_string(folder, PSRV_PRINTER_ATTR_DRV_NAME, argv[3]);
		write_string(folder, PSRV_PRINTER_ATTR_TRANSPORT, argv[4]);
		write_string(folder, PSRV_PRINTER_ATTR_TRANSPORT_ADDR,
			argc > 5 ? argv[5] : "");
		write_string(folder, PSRV_PRINTER_ATTR_CNX, "Local");
		write_string(folder, PSRV_PRINTER_ATTR_STATE, "free");

		BEntry entry(temporary.Path());
		BDirectory target(printers.Path());
		status = entry.MoveTo(&target, name);
		if (status != B_OK) {
			fprintf(stderr, "cannot move the printer into %s: %s\n",
				printers.Path(), strerror(status));
			entry.Remove();
			return 1;
		}
		printf("added %s\n", name);
		return 0;
	}

	if (strcmp(argv[1], "remove") == 0) {
		BPath path(printers);
		path.Append(name);
		BDirectory dir(path.Path());
		BEntry entry;
		while (dir.GetNextEntry(&entry) == B_OK)
			entry.Remove();
			// spooled jobs
		status_t status = BEntry(path.Path()).Remove();
		if (status != B_OK) {
			fprintf(stderr, "cannot remove %s: %s\n", path.Path(),
				strerror(status));
			return 1;
		}
		return 0;
	}

	if (strcmp(argv[1], "default") == 0) {
		BMessenger server(PSRV_SIGNATURE_TYPE);
		if (!server.IsValid()) {
			be_roster->Launch(PSRV_SIGNATURE_TYPE);
			for (int i = 0; i < 50 && !server.IsValid(); i++) {
				snooze(100000);
				server = BMessenger(PSRV_SIGNATURE_TYPE);
			}
		}
		if (!server.IsValid()) {
			fprintf(stderr, "cannot start print_server\n");
			return 1;
		}
		BMessage message(PSRV_MAKE_PRINTER_ACTIVE_QUIETLY);
		message.AddString("printer", name);
		BMessage reply;
		status_t status = server.SendMessage(&message, &reply);
		if (status != B_OK) {
			fprintf(stderr, "print_server: %s\n", strerror(status));
			return 1;
		}
		return 0;
	}

	return usage();
}
