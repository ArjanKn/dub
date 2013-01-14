/**
	Management of packages on the local computer.

	Copyright: © 2012 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Matthias Dondorff
*/
module dub.packagemanager;

import dub.dependency;
import dub.installation;
import dub.package_;
import dub.utils;

import std.algorithm : countUntil, filter, sort;
import std.exception;
import std.file;
import std.zip;
import vibe.core.file;
import vibe.core.log;
import vibe.data.json;
import vibe.inet.path;
import vibe.stream.operations;


enum PackageJsonFileName = "package.json";


class PackageManager {
	private {
		Path m_systemPackagePath;
		Path m_userPackagePath;
		Path m_projectPackagePath;
		Package[][string] m_systemPackages;
		Package[][string] m_userPackages;
		Package[string] m_projectPackages;
		Package[] m_localPackages;
	}

	this(Path system_package_path, Path user_package_path, Path project_package_path)
	{
		m_systemPackagePath = system_package_path;
		m_userPackagePath = user_package_path;
		m_projectPackagePath = project_package_path;
		refresh();
	}

	Package getPackage(string name, Version ver)
	{
		foreach( p; getPackageIterator(name) )
			if( p.ver == ver )
				return p;
		return null;
	}

	Package getBestPackage(string name, string version_spec)
	{
		return getBestPackage(name, new Dependency(version_spec));
	}

	Package getBestPackage(string name, in Dependency version_spec)
	{
		Package ret;
		foreach( p; getPackageIterator(name) )
			if( version_spec.matches(p.ver) && (!ret || p.ver > ret.ver) )
				ret = p;
		return ret;
	}

	int delegate(int delegate(ref Package)) getPackageIterator(string name)
	{
		int iterator(int delegate(ref Package) del)
		{
			// first search project local packages
			if( auto pp = name in m_projectPackages )
				if( auto ret = del(*pp) ) return ret;

			// then local packages
			foreach( p; m_localPackages )
				if( p.name == name )
					if( auto ret = del(p) ) return ret;

			// then user installed packages
			if( auto pp = name in m_userPackages )
				foreach( v; *pp )
					if( auto ret = del(v) )
						return ret;

			// finally system-wide installed packages
			if( auto pp = name in m_systemPackages )
				foreach( v; *pp )
					if( auto ret = del(v) )
						return ret;

			return 0;
		}

		return &iterator;
	}

	Package install(Path zip_file_path, Json package_info, InstallLocation location)
	{
		auto package_name = package_info.name.get!string();
		auto package_version = package_info["version"].get!string();

		Path destination;
		final switch( location ){
			case InstallLocation.Local: destination = Path(package_name); break;
			case InstallLocation.ProjectLocal: destination = m_projectPackagePath ~ package_name; break;
			case InstallLocation.UserWide: destination = m_userPackagePath ~ (package_name ~ "/" ~ package_version); break;
			case InstallLocation.SystemWide: destination = m_systemPackagePath ~ (package_name ~ "/" ~ package_version); break;
		}

		if( existsFile(destination) )
			throw new Exception(package_name~" needs to be uninstalled prior installation.");

		// open zip file
		ZipArchive archive;
		{
			auto f = openFile(zip_file_path, FileMode.Read);
			scope(exit) f.close();
			archive = new ZipArchive(f.readAll());
		}

		logDebug("Installing from zip.");

		// In a github zip, the actual contents are in a subfolder
		Path zip_prefix;
		foreach(ArchiveMember am; archive.directory)
			if( Path(am.name).head == PathEntry("package.json") ){
				zip_prefix = Path(am.name)[0 .. 1];
				break;
			}

		if( zip_prefix.empty ){
			// not correct zip packages HACK
			Path minPath;
			foreach(ArchiveMember am; archive.directory)
				if( isPathFromZip(am.name) && (minPath == Path() || minPath.startsWith(Path(am.name))) )
					zip_prefix = Path(am.name);
		}

		logDebug("zip root folder: %s", zip_prefix);

		Path getCleanedPath(string fileName) {
			auto path = Path(fileName);
			if(zip_prefix != Path() && !path.startsWith(zip_prefix)) return Path();
			return path[zip_prefix.length..path.length];
		}

		// install
		mkdirRecurse(destination.toNativeString());
		auto journal = new Journal;
		foreach(ArchiveMember a; archive.directory) {
			auto cleanedPath = getCleanedPath(a.name);
			if(cleanedPath.empty) continue;
			auto dst_path = destination~cleanedPath;

			logDebug("Creating %s", cleanedPath);
			if( dst_path.endsWithSlash ){
				if( !existsDirectory(dst_path) )
					mkdirRecurse(dst_path.toNativeString());
				journal.add(Journal.Entry(Journal.Type.Directory, cleanedPath));
			} else {
				if( !existsDirectory(dst_path.parentPath) )
					mkdirRecurse(dst_path.parentPath.toNativeString());
				auto dstFile = openFile(dst_path, FileMode.CreateTrunc);
				scope(exit) dstFile.close();
				dstFile.write(archive.expand(a));
				journal.add(Journal.Entry(Journal.Type.RegularFile, cleanedPath));
			}
		}

		{ // overwrite package.json (this one includes a version field)
			Json pi = jsonFromFile(destination~"package.json");
			auto pj = openFile(destination~"package.json", FileMode.CreateTrunc);
			scope(exit) pj.close();
			pi["version"] = package_info["version"];
			toPrettyJson(pj, pi);
		}

		// Write journal
		logTrace("Saving installation journal...");
		journal.add(Journal.Entry(Journal.Type.RegularFile, Path("journal.json")));
		journal.save(destination ~ "journal.json");

		if( existsFile(destination~"package.json") )
			logInfo("%s has been installed with version %s", package_name, package_version);

		auto pack = new Package(location, destination);
		final switch( location ){
			case InstallLocation.Local: break;
			case InstallLocation.ProjectLocal: m_projectPackages[package_name] = pack; break;
			case InstallLocation.UserWide: m_userPackages[package_name] ~= pack; break;
			case InstallLocation.SystemWide: m_systemPackages[package_name] ~= pack; break;
		}
		return pack;
	}

	void uninstall(in Package pack)
	{
		enforce(!pack.path.empty, "Cannot uninstall package "~pack.name~" without a path.");

		// remove package from package list
		final switch(pack.installLocation){
			case InstallLocation.Local: assert(false, "Cannot uninstall locally installed package.");
			case InstallLocation.ProjectLocal:
				auto pp = pack.name in m_projectPackages;
				assert(pp !is null, "Package "~pack.name~" at "~pack.path.toNativeString()~" is not installed in project.");
				assert(*pp is pack);
				m_projectPackages.remove(pack.name);
				break;
			case InstallLocation.UserWide:
				auto pv = pack.name in m_systemPackages;
				assert(pv !is null, "Package "~pack.name~" at "~pack.path.toNativeString()~" is not installed in user repository.");
				auto idx = countUntil(*pv, pack);
				assert(idx < 0 || (*pv)[idx] is pack);
				if( idx >= 0 ) *pv = (*pv)[0 .. idx] ~ (*pv)[idx+1 .. $];
				break;
			case InstallLocation.SystemWide:
				auto pv = pack.name in m_userPackages;
				assert(pv !is null, "Package "~pack.name~" at "~pack.path.toNativeString()~" is not installed system repository.");
				auto idx = countUntil(*pv, pack);
				assert(idx < 0 || (*pv)[idx] is pack);
				if( idx >= 0 ) *pv = (*pv)[0 .. idx] ~ (*pv)[idx+1 .. $];
				break;
		}

		// delete package files physically
		auto journalFile = pack.path~"journal.json";
		if( !existsFile(journalFile) )
			throw new Exception("Uninstall failed, no journal found for '"~pack.name~"'. Please uninstall manually.");

		auto packagePath = pack.path;
		auto journal = new Journal(journalFile);
		logDebug("Erasing files");
		foreach( Journal.Entry e; filter!((Journal.Entry a) => a.type == Journal.Type.RegularFile)(journal.entries)) {
			logTrace("Deleting file '%s'", e.relFilename);
			auto absFile = pack.path~e.relFilename;
			if(!existsFile(absFile)) {
				logWarn("Previously installed file not found for uninstalling: '%s'", absFile);
				continue;
			}

			removeFile(absFile);
		}

		logDebug("Erasing directories");
		Path[] allPaths;
		foreach(Journal.Entry e; filter!((Journal.Entry a) => a.type == Journal.Type.Directory)(journal.entries))
			allPaths ~= pack.path~e.relFilename;
		sort!("a.length>b.length")(allPaths); // sort to erase deepest paths first
		foreach(Path p; allPaths) {
			logTrace("Deleting folder '%s'", p);
			if( !existsFile(p) || !isDir(p.toNativeString()) || !isEmptyDir(p) ) {
				logError("Alien files found, directory is not empty or is not a directory: '%s'", p);
				continue;
			}
			rmdir(p.toNativeString());
		}

		if(!isEmptyDir(pack.path))
			throw new Exception("Alien files found in '"~pack.path.toNativeString()~"', needs to be deleted manually.");

		rmdir(pack.path.toNativeString());
		logInfo("Uninstalled package: '"~pack.name~"'");
	}

	void refresh()
	{
		// rescan the system package folder
		m_systemPackages = null;
		if( m_systemPackagePath.existsDirectory() ){
			logDebug("iterating dir %s", m_systemPackagePath.toNativeString());
			try foreach( pdir; iterateDirectory(m_systemPackagePath) ){
				logDebug("iterating dir %s entry %s", m_systemPackagePath.toNativeString(), pdir.name);
				if( !pdir.isDirectory ) continue;
				Package[] vers;
				auto pack_path = m_systemPackagePath ~ pdir.name;
				foreach( vdir; iterateDirectory(pack_path) ){
					if( !vdir.isDirectory ) continue;
					auto ver_path = pack_path ~ vdir.name;
					if( !existsFile(ver_path ~ PackageJsonFileName) ) continue;
					try {
						auto p = new Package(InstallLocation.SystemWide, ver_path);
						vers ~= p;
					} catch( Exception e ){
						logError("Failed to load package in %s: %s", ver_path, e.msg);
					}
				}
				m_systemPackages[pdir.name] = vers;
			}
			catch(Exception e) logDebug("Failed to enumerate system packages: %s", e.toString());
		}

		// rescan the user package folder
		m_userPackages = null;
		if( m_systemPackagePath.existsDirectory() ){
			logDebug("iterating dir %s", m_userPackagePath.toNativeString());
			try foreach( pdir; m_userPackagePath.iterateDirectory() ){
				if( !pdir.isDirectory ) continue;
				Package[] vers;
				auto pack_path = m_userPackagePath ~ pdir.name;
				foreach( vdir; pack_path.iterateDirectory() ){
					if( !vdir.isDirectory ) continue;
					auto ver_path = pack_path ~ vdir.name;
					if( !existsFile(ver_path ~ PackageJsonFileName) ) continue;
					try {
						auto p = new Package(InstallLocation.UserWide, ver_path);
						vers ~= p;
					} catch( Exception e ){
						logError("Failed to load package in %s: %s", ver_path, e.msg);
					}
				}
				m_userPackages[pdir.name] = vers;
			}
			catch(Exception e) logDebug("Failed to enumerate user packages: %s", e.toString());
		}

		// rescan the project package folder
		m_projectPackages = null;
		if( m_projectPackagePath.existsDirectory() ){
			logDebug("iterating dir %s", m_projectPackagePath.toNativeString());
			try foreach( pdir; m_projectPackagePath.iterateDirectory() ){
				if( !pdir.isDirectory ) continue;
				auto pack_path = m_projectPackagePath ~ pdir.name;
				if( !existsFile(pack_path ~ PackageJsonFileName) ) continue;

				try {
					auto p = new Package(InstallLocation.ProjectLocal, pack_path);
					m_projectPackages[pdir.name] = p;
				} catch( Exception e ){
					logError("Failed to load package in %s: %s", pack_path, e.msg);
				}
			}
			catch(Exception e) logDebug("Failed to enumerate project packages: %s", e.toString());
		}

		// load locally defined packages
		foreach( list_path; [m_systemPackagePath, m_userPackagePath] ){
			try {
				logDebug("Looking for local package map at %s", list_path.toNativeString());
				if( !existsFile(list_path ~ "local-packages.json") ) continue;
				logDebug("Try to load local package map at %s", list_path.toNativeString());
				auto packlist = jsonFromFile(list_path ~ "local-packages.json");
				enforce(packlist.type == Json.Type.Array, "local-packages.json must contain an array.");
				foreach( pentry; packlist ){
					try {
						auto name = pentry.name.get!string();
						auto ver = pentry["version"].get!string();
						auto path = Path(pentry.path.get!string());
						auto info = Json.EmptyObject;
						if( existsFile(path ~ "package.json") ) info = jsonFromFile(path ~ "package.json");
						if( "name" in info && info.name.get!string() != name )
							logWarn("Local package at %s has different name than %s (%s)", path.toNativeString(), name, info.name.get!string());
						info.name = name;
						info["version"] = ver;
						auto pp = new Package(info, InstallLocation.Local, path);
						m_localPackages ~= pp;
					} catch( Exception e ){
						logWarn("Error adding local package: %s", e.msg);
					}
				}
			} catch( Exception e ){
				logDebug("Loading of local package list at %s failed: %s", list_path.toNativeString(), e.msg);
			}
		}
	}
}