# Apache Nifi & Postgresql

TODO: add more details

### Start

```sh
docker-compose up -d
```

### Status check

```bash
docker-compose logs -f nifi
```

Once you see `NiFi has started`, NiFi should be available at [https://localhost:8443/nifi](https://localhost:8443/nifi).
_Please note_ the browser warning and accept the self-signed certificate.


### Stop

```sh
docker-compose stop
```
