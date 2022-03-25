# nagios-plugins-informix

This plugins check an Informix DB for various metrics. Obvously, you need Informix Client SDK.

#Usage :

check_indformix.pl -H [host FQDN or IP] --extra-opts='IFX@/some/path/informix.ini'  -C [command]

where informix.ini does contain :
```
[IFX]
port = [port]
instance = [instance name]
user = [username]
password = [password]
env = [name of the environment, for Prometheus metrics]
hostname = [FQDN of the host]
hostID = [free field, for Prometheus metrics]
```
# Commands :
* uptime : uptime of the database
* version : version the Informix server
* status : one of `Initialisation, Quiescent, Recovery, Backup, Shutdown, Online, Offline`
* dbspaces : space used by databases, warning/critical thersholds in MB, can be omitted
* ratio : size of the pages. returns `db_name, pages_size, pages_free, free%`
* dbsizes : similar to `dbspaces` returns data ans index sizes
* logsize : returns the physical size of the log
* locksessions : number of locked sessions
* checkpoints : number of checkpoints
* chunkoffline : returns the number of offline chunks
* ioperchunk : pages read/written per chunk
* statistics : various statistics from the database
* infos : combines `version, uptime, status and statistics`
* sharedmemstats : collects metrics for `Resident, Virtual, Message, Buffer`
* bigsessions : number of sessions > 100MB
* totalmem : percent of total mem used
* nonsavedlogs : non saved transactional logs
* listlogs : list transactional logs with percent memory used

# Example :
```
(see configs/check_informix.cfg for details)
define service {
	check_command          check_informix_aa!--extra-opts='IFX@/etc/nagios/extraopts/informix.ini' -C statistics
	host_name              <nagios name of the host>
	service_description    Informix Statistics
	use                    default-service
}
```
