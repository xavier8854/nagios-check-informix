#######################################################################
# $Id: nagios-plugins-informix, v1.0 r1 16.03.2021 12:11:01 CET XH Exp $
#
# Copyright 2021 Xavier Humbert <xavier.humbert@ac-nancy-metz.fr>
# for CRT SUP
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301, USA.
#
#######################################################################
# Release number :
%define rel %(date '+%Y%m%d%H%M')

# plugins install path:
%define pluginsdir  %{_libdir}/nagios/plugins

# plugins configuration path :
%define configdir  %{_sysconfdir}/racvision

# locale path (i18n):
%define locale_path %{_prefix}/share/locale

Name:			nagios-plugins-informix
Version:		1.2.1
Release:		%{rel}%{?dist}
License:		GPL
Group:			Application/System
Summary:		Informix perl plugins for Nagios
Source0:		%{name}-plugins.tar.bz2
Source1:		%{name}-configs.tar.bz2
BuildRoot:		%{_tmppath}/%{name}-buildroot
BuildArch:		noarch
Requires:		ibminformix-libs >= 4.1
Requires:		perl-Monitoring-Plugin >= 0.38

%description

This package contain Informix Nagios perl plugins.

%description -l fr_FR

Ce package contient des plugins Nagios pour Informix écrits en Perl.

%{?perl_default_filter}
%global __requires_exclude %{?__requires_exclude}|perl\\(utils\\)

%prep
%setup -q -n plugins
%{__tar} --overwrite -xjf %{SOURCE1}

%build
echo $RPM_BUILD_ROOT

%install
%{__rm} -rf $RPM_BUILD_ROOT
%{__install} -m 0755 -d ${RPM_BUILD_ROOT}/%{pluginsdir}
%{__install} -m 0755 check_*.pl ${RPM_BUILD_ROOT}/%{pluginsdir}

%{__install} -m 0755 -d ${RPM_BUILD_ROOT}/%{_sysconfdir}/nagios/commands
%{__install} -m 0644 configs/*.cfg ${RPM_BUILD_ROOT}/%{_sysconfdir}/nagios/commands/

%{__install} -m 0755 -d ${RPM_BUILD_ROOT}/%{_sysconfdir}/nagios/extraopts
%{__install} -m 0644 configs/*.ini ${RPM_BUILD_ROOT}/%{_sysconfdir}/nagios/extraopts/


%files
%defattr(644,root,root)
%attr(755,root,root) %{pluginsdir}/check_*.pl
%config(noreplace) %{_sysconfdir}/nagios/commands/check_informix.cfg
%config(noreplace) %{_sysconfdir}/nagios/extraopts/informix.ini


# LANG=EN-US date +"%a %b %d %Y" -d today

%changelog
* Thu Oct 28 2021 Xavier Humbert <xavier.humbert@ac-nancy-metz.fr> - 1.2.1
- Add Hostname as key for sections in INI file

* Wed Oct 27 2021 Xavier Humbert <xavier.humbert@ac-nancy-metz.fr> - 1.2
- Multivalued tresholds for 2 functions, stored in INI file

* Wed Sep 1 2021 Xavier Humbert <xavier.humbert@ac-nancy-metz.fr> - 1.1
- Echo perfdatas in OpenMetrics files. Works together with perl-PrometheusMetrics

* Thu Jun 17 2021 Xavier Humbert <xavier.humbert@ac-nancy-metz.fr> - 1.0.1
- Move ld.so.conf.d Informix.conf to the logical place : ibminformix-libs
- Removed debug code

* Thu Mar 18 2021 Xavier Humbert <xavier.humbert@ac-nancy-metz.fr> - 1.0
- Initial commit
