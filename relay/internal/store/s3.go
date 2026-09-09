package store

import (
	"context"
	"errors"
	"io"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// S3 keeps objects in one bucket under a prefix. Credentials and region
// come from the usual AWS environment (instance role, env, profile).
type S3 struct {
	Client *s3.Client
	Bucket string
	Prefix string // "" or "something/" — always ends in a slash when set
}

func (s *S3) key(k string) string { return s.Prefix + k }

func (s *S3) Put(ctx context.Context, key string, r io.Reader, size int64) error {
	_, err := s.Client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(s.Bucket),
		Key:           aws.String(s.key(key)),
		Body:          r,
		ContentLength: aws.Int64(size),
		ContentType:   aws.String("application/octet-stream"),
	})
	return err
}

func (s *S3) Get(ctx context.Context, key string) (io.ReadCloser, int64, error) {
	out, err := s.Client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(s.Bucket), Key: aws.String(s.key(key)),
	})
	if err != nil {
		var nsk *types.NoSuchKey
		if errors.As(err, &nsk) {
			return nil, 0, ErrNotFound
		}
		return nil, 0, err
	}
	return out.Body, aws.ToInt64(out.ContentLength), nil
}

func (s *S3) Head(ctx context.Context, key string) (bool, error) {
	_, err := s.Client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(s.Bucket), Key: aws.String(s.key(key)),
	})
	if err != nil {
		var nf *types.NotFound
		if errors.As(err, &nf) || strings.Contains(err.Error(), "NotFound") {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func (s *S3) List(ctx context.Context, prefix string) ([]string, error) {
	out := []string{}
	p := s3.NewListObjectsV2Paginator(s.Client, &s3.ListObjectsV2Input{
		Bucket: aws.String(s.Bucket), Prefix: aws.String(s.key(prefix)),
	})
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, o := range page.Contents {
			out = append(out, strings.TrimPrefix(aws.ToString(o.Key), s.Prefix))
		}
	}
	return out, nil
}

func (s *S3) Delete(ctx context.Context, key string) error {
	_, err := s.Client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.Bucket), Key: aws.String(s.key(key)),
	})
	return err
}
