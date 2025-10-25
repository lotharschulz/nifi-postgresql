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

Login with [user name and password provided](https://github.com/lotharschulz/nifi-postgresql/commit/88738f100150cc32f76b2109ddb803965e972468#diff-e45e45baeda1c1e73482975a664062aa56f20c03dd9d64a827aba57775bed0d3R29-R30)


### Stop

```sh
docker-compose stop
```
