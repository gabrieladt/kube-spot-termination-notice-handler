FROM alpine:3.6

RUN apk -v --update add \
        python \
        py-pip \
        groff \
        less \
        mailcap \
        curl \
        ca-certificates \
        && \
    pip install --upgrade awscli==1.14.40 python-magic && \
    apk -v --purge del py-pip && \
    rm /var/cache/apk/*

ARG KUBE_VERSION=1.10.0
ENV HOME=/srv
WORKDIR /srv

RUN curl -f -s -o /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v${KUBE_VERSION}/bin/linux/amd64/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    kubectl version --client

# Copy entrypoint.sh
COPY entrypoint.sh .

# Set permissions on the file.
RUN chmod +x entrypoint.sh


CMD ["/srv/entrypoint.sh"]
