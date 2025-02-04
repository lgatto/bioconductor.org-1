#!/usr/bin/env ruby

require 'find'
require 'rss'
require 'pp'
require 'yaml'
require 'fileutils'
require 'rubygems'
require 'uuid'
require 'rexml/document'
require 'redis'
include REXML



if ARGV.empty?
    $buildtype = "bioc"
else
    unless ["bioc", "data-annotation", "data-experiment", "workflows", "books", "bioc-longtests"].include? ARGV.first
        puts "argument must be 'bioc', 'data-annotation', 'data-experiment', 'workflows', 'books', or 'bioc-longtests'"
        exit 1
    else
        $buildtype = ARGV.first
    end
end

$uuid = UUID.new
BASEURL = "http://bioconductor.org/checkResults"

if $buildtype == "bioc"
    DCFDIR = "tmp/build_dcfs"
    OUTSUBDIR = "rss/build"
    RSSFILE = "tmp/rss_urls.txt"
elsif $buildtype == "data-annotation"
    DCFDIR = "tmp/data_annnotation_build_dcfs"
    OUTSUBDIR = "rss/build/data-annotation"
    RSSFILE = "tmp/data_annnotation_rss_urls.txt"
elsif $buildtype == "data-experiment"
    DCFDIR = "tmp/data_experiment_build_dcfs"
    OUTSUBDIR = "rss/build/data-experiment"
    RSSFILE = "tmp/data_experiment_rss_urls.txt"
elsif $buildtype == "workflows"
    DCFDIR = "tmp/workflows_build_dcfs"
    OUTSUBDIR = "rss/build/workflows"
    RSSFILE = "tmp/workflows_rss_urls.txt"
elsif $buildtype == "books"
    DCFDIR = "tmp/books_build_dcfs"
    OUTSUBDIR = "rss/build/books"
    RSSFILE = "tmp/books_rss_urls.txt"
else
    DCFDIR = "tmp/longtests_build_dcfs"
    OUTSUBDIR = "rss/build/longtests"
    RSSFILE = "tmp/longtests_rss_urls.txt"
end

OUTDIR="assets/#{OUTSUBDIR}"

$results = {release: [], devel: []}
for vers in [:release, :devel]
    f = File.open(File.join(DCFDIR, vers.to_s, "BUILD_STATUS_DB.txt"))
    lines = f.readlines()
    for line in lines
        key, val = line.strip.split(": ")
        $results[vers] << {key => val}
    end
end

$urls = []

def get_status(path)
    f = File.open(path)
    lines = f.readlines
    statusline = lines.find {|i| i =~ /^Status: /}
    statusline = statusline.chomp.sub(/^Status: /, "")
    statusline
end

def tweak(rss, outfile)
    #return rss.to_s if true
    outfile.gsub! /#{OUTDIR}/, ""
    outfile.gsub! /^\//, ""
    url = "http://bioconductor.org/#{OUTSUBDIR}/#{outfile}"
    xml = Document.new rss.to_s
    hub_link =  Element.new "link" #e.add_element("link")
    hub_link.attributes["rel"] = "hub"
    hub_link.attributes["href"] = $hub_url
    self_link = Element.new "link" #e.add_element("link")
    self_link.attributes["rel"] = "self"
    self_link.attributes["href"] = url
    self_link.attributes["type"] = "application/atom+xml"
    $urls.push url

    xml.root.insert_after "//feed/updated", self_link
    xml.root.insert_after "//feed/updated", hub_link
    #xml.root.elements["entry"].add Text.new("Bioconductor Build Information")
    tmp = XPath.match xml, "//entry"
    for thing in tmp
        date = XPath.first(thing, "dc:date")
        thing.delete date
    end

    return xml.to_s
end


def make_problem_feed(pkglist, config, problems, outfile)
    rss = RSS::Maker.make("atom") do |maker|
        maker.channel.author = "Bioconductor Build System"
        maker.channel.updated = Time.now.to_s
        ## FIXME: add content here:
        maker.channel.about = "http://bioconductor.org/developers/rss-feeds/"
        if problems.include? "WARNINGS"
            maker.channel.title = "Build Problems (including warnings)"
        else
            maker.channel.title = "Build Problems (excluding warnings)"
        end


        for key in pkglist.keys.sort  {|a,b| b.downcase <=> a.downcase}
            bad = pkglist[key].find_all {|i| problems.include? i[:status] }
            for b in bad
                maker.items.new_item do |item|
                    item.link = "#{BASEURL}/#{b[:version]}/#{$buildtype}-LATEST/#{key}/#{b[:node]}-#{b[:phase]}.html"
                    item.title = "#{b[:status]} in #{b[:version]} version of #{key} on node #{b[:node]}"
                    item.summary = item.title
                    item.updated = Time.now.to_s
                    item.id = "#{item.link}?id=#{Time.now.to_i}_#{$uuid.generate}"
                end
            end
        end
    end
    FileUtils.mkdir_p OUTDIR
    f = File.open("#{OUTDIR}/#{outfile}", "w")
    tweaked = tweak(rss, outfile)
    f.puts tweaked
    f.close
end

def make_individual_feed(pkglist, config, pkgs_to_update)
    rootdir =  "#{OUTDIR}/packages"
    FileUtils.mkdir_p rootdir
    for key in  pkgs_to_update #pkglist.keys
        filename = "#{rootdir}/#{key}.rss"
        bad = pkglist[key].find_all {|i| i[:status] != "OK"}
        rss = RSS::Maker.make("atom") do |maker|
            maker.channel.author = "Bioconductor Build System"
            maker.channel.title = "#{key} Build Problems"
            maker.channel.updated = Time.now.to_s
            ## FIXME: add content here:
            maker.channel.about = "http://bioconductor.org/developers/rss-feeds/"

            if bad.empty?
                maker.items.new_item do |item|
                    if pkglist[key].find {|i| i[:version] == "release"}
                        version = "release"
                    else
                        version = "devel"
                    end
                    item.link = "#{BASEURL}/#{version}/#{$buildtype}-LATEST/#{key}/"
                    item.updated = Time.now.to_s
                    item.title = "No build problems for #{key}."
                    item.summary = item.title
                    item.id = "#{item.link}?id=#{Time.now.to_i}_#{$uuid.generate}"
                end
            else
                relprobs = bad.find_all {|i| i[:version] == "release"}
                devprobs = bad.find_all {|i| i[:version] == "devel"}
                os = {"linux" => 1, "windows" => 2,
                      "mac_snowleopard" => 3,
                      "mac_mavericks" => 4,
                      "mac_elcapitan" => 5,
                      "mac_highsierra" => 6,
                      "mac_mojave" => 7}
                for ary in [relprobs, devprobs]
                    machines = ary == relprobs ? config["active_release_builders"] : config["active_devel_builders"]
                    ary = ary.find_all{|i| machines.values.include? i[:node]}
                    ary.sort! do |a, b|
                        nodea = a[:node]
                        nodeb = b[:node]
                        osa = machines.find{|k,v| v == nodea}.first
                        osb = machines.find{|k,v| v == nodeb}.first
                        if (os[osa] > os[osb])
                            1
                        elsif os[osa] < os[osb]
                            -1
                        else
                            0
                        end
                    end
                    next if ary.empty?
                    version = ary.first[:version]
                    probs = ary.collect{|i| i[:status]}
                    nodes = ary.collect{|i| i[:node]}
                    maker.items.new_item do |item|
                        item.link = "#{BASEURL}/#{version}/#{$buildtype}-LATEST/#{key}/"
                        nword = (nodes.length > 1) ? "nodes" : "node"
                        item.title = "#{key} #{probs.join "/"} in #{version} on #{nword} #{nodes.join "/"}"
                        item.summary = item.title
                        item.updated = Time.now.to_s
                        item.id = "#{item.link}?id=#{Time.now.to_i}_#{$uuid.generate}"

                    end
                end
            end

        end
        #if (not bad.empty?) or (not file_exists)
        f = File.open(filename, "w")
        #puts filename
        tweaked = tweak(rss, filename)
        f.puts tweaked #rss
        f.close
        #end
    end
end

def runit()
    redis = Redis.new
    pkglist = {}
    pkgs_to_update = {}
    config = YAML.load_file("./config.yaml")
    $hub_url = config["rss_hub_url"]
    for vers in [:release, :devel]
        db = $results[vers]
        for item in db
            k = item.keys.first
            v = item.values.first
            pkg, node, phase = k.split("#")
            status = v
            pkglist[pkg] = [] unless pkglist.has_key? pkg
            pkglist[pkg].push(:version => vers.to_s, :node => node,
                :phase => phase, :status => status)

            key = "#{vers.to_s}_#{node}_#{phase}"
            oldstatus = redis.hget(pkg, key)
            rhash = redis.hgetall(pkg)

            if (oldstatus.nil? or oldstatus != status)
                pkgs_to_update[pkg] = 1
                redis.hset(pkg, key, status)
            end



        end
    end

    make_problem_feed(pkglist, config, ["ERROR", "WARNINGS", "TIMEOUT"],
        "problems.rss")
    make_problem_feed(pkglist, config, ["ERROR", "TIMEOUT"],
        "errors.rss")
    puts "making #{pkgs_to_update.keys.length} updated individual pkg rss files"
    make_individual_feed(pkglist, config, pkgs_to_update.keys)
    puts "Done at #{Time.now.to_s}"
    FileUtils.rm_f RSSFILE
    urlfile = File.open(RSSFILE, "w")
    for url in $urls
        urlfile.puts url
    end
    urlfile.close
    pkglist
end

#runit()
if $0 == __FILE__
    runit()
end
