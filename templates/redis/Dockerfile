ARG BASE_IMAGE=redis:7.4.2
FROM ${BASE_IMAGE}

RUN mkdir -p /data && chown -R redis:redis /data

COPY redis.conf /usr/local/etc/redis/redis.conf

CMD [ "redis-server", "/usr/local/etc/redis/redis.conf" ]
