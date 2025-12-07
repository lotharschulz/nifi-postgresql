# Apache Nifi & Postgresql

TODO: add more details

### Start

```sh
docker-compose up -d
```

### Status check

verify environment variables are loaded
```bash
docker-compose config
```

Wait for services to start (NiFi takes some time to start) and check nifi status
```bash
docker-compose logs -f nifi
```

Once you see `NiFi has started`, NiFi should be available at [https://localhost:8443/nifi](https://localhost:8443/nifi).
_Please note_ the browser warning and accept the self-signed certificate.

Login with user name and password provided defined in your .env file.


### Stop

```sh
# Data is preserved in Docker volumes. To remove volumes as well (irreversible), run:
docker-compose stop -v 
```

### Restart from scratch

```sh
docker-compose down -v && sleep 2 && docker-compose up -d
```
